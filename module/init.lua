--[[
  Ally Support

  The game already lets an AI ally help a human: it sends goods when the player asks (if it has
  enough left over by its AIC rule MinimumGoodsRequiredAfterTrade), and it sends its attack
  troops to the player's keep when asked for help (if it is not nervous itself and has at least
  AttForceSupportAllyThreshold attack troops). Between AI allies none of this happens:

  * An AI short of goods it cannot buy calls requestGoods, which writes the request into the
    request slot of every teammate (PlayerData.requestedGoodsArray1Unk[requester] = resource,
    ...Array2Unk[requester] = amount). Only a human ever answers it, so the slots of AI
    teammates fill up and stay full.
  * A nervous AI (enemies near its keep, PlayerData.isNotNervousByEnemyTroopValue = 1, the name
    is the wrong way round) only asks the human player for help.

  This module runs once per AI player per AI cycle, right before the AI's food purchase plan
  (setFoodBuyPlan, the third call in updateAIBehaviour's per player block), and:

  1. Goods: answers the requests in that AI's slots from AI allies with the same AIC test the
     game uses for the player (isResourceLargerOrEqualThanMinimumGoodsRequiredAfterTrade) and the
     same transfer (processResourceGain / processResourceLoss). A request is cleared either way,
     and once one ally has sent the goods the same request is cleared from the other AI allies.
  2. Gold: a lord asked for goods that holds at least 100 x its MinimumGoodsRequiredAfterTrade in
     gold also sends the asker a share of the gold above that line.
  3. Help: an idle AI that is not nervous and has its AIC's support threshold of attack troops
     answers a nervous AI ally the way it answers the player: requestStateUnk = 2,
     playerID_askerUnk = the ally. The AI's own state machine then sends the attack troops to
     that keep every cycle. The request is dropped when the ally is safe again.
  4. Army share: whenever an AI is helping anyone (player or AI), its attack troops are topped up
     once to 75% of its whole army, taking raiders, patrols and defenders into the main army
     troop, and the relief is sent at once.
]]

local MODULE_NAME = "ally-support"

local DEFAULTS = {
  goods = { enabled = true },
  gold = { enabled = true, factor = 100, share = 25 },
  help = { enabled = true },
  army = { enabled = true, share = 75 },
  diagnostics = { log = false },
}

---------------------------------------------------------------------------------------
-- What the game's code looks like where this module reads it
---------------------------------------------------------------------------------------

-- updateAIBehaviour, per AI player: updateAIPlayerState / aiUpdateTaxesAndRations /
-- setFoodBuyPlan. lord-hunt hooks the second call; this module the third.
local AOB_CALLS = "57 8B CB E8 ? ? ? ? 57 8B CB E8 ? ? ? ? 57 8B CB E8 ? ? ? ? 39 3D ? ? ? ? 74"
local CALL_HOOK = 0x13

-- AICState::addUnitToItsTribe(unit, behaviour)
local AOB_ADD_TO_ITS_TRIBE = "56 57 8B 7C 24 0C 8B C7 69 C0 90 04 00 00 0F BF 90 ? ? ? ? 8B F2 69 F6 F4 39 00 00"
local ITS_UNIT_OWNER = { 0x0E, { 0x0F, 0xBF, 0x90 } }
local ITS_AI_TYPE = { 0x1D, { 0x83, 0xBE } }
local ITS_TRIBES = { 0x3F, { 0xB9 } }
local AOB_REMOVE_FROM_TRIBE = "53 55 56 8B 74 24 10 8B D9 8B CE 69 C9 90 04 00 00 66 83 B9 ? ? ? ? 00 57 8B 7C 24 18"
local REMOVE_STRIDE = { 0x5B, { 0x69, 0xC0 } }

-- ProcessAllyRequestingGoods, the branch where an AI ally sends the player what he asked for.
local AOB_GIFT = "53 8B 5C 24 1C 55 53 56 B9 ? ? ? ? E8 ? ? ? ? 8B 6C 24 1C 55 57 53 B9 ? ? ? ? E8 ? ? ? ? 6A 00 55 57 56 B9 ? ? ? ? E8"
local GIFT_BUILDINGS = { 0x19, { 0xB9 } }
local GIFT_GAIN = 0x1E
local GIFT_LOSS = 0x2D

-- AICState::isResourceLargerOrEqualThanMinimumGoodsRequiredAfterTrade(player, resource, amount)
local AOB_ENOUGH = "8B 44 24 04 8B D0 69 D2 F4 39 00 00 8B 92 ? ? ? ? 85 D2 75 06 8D 42 01 C2 0C 00"

-- updateAIPlayerState: requestStateUnk 2 -> clearRallyFlagOnAllAIAttackTribes,
-- sendUnitsToPlayerIDsKeepIfPossible(player, playerID_askerUnk).
local AOB_SEND = "8B 87 ? ? ? ? 83 F8 01 74 ? 83 F8 02 75 ? 8B 87 ? ? ? ? 50 B9"
local SEND_STATE = { 0x00, { 0x8B, 0x87 } }
local SEND_ASKER = { 0x10, { 0x8B, 0x87 } }
local SEND_CLEAR_RALLY = 0x28
local SEND_TROOPS = 0x37

local AOB_TEAMS = "8B 0C 85 ? ? ? ? 8B 44 24 30 3B 0C 85 ? ? ? ?"
local TEAMS_OPERAND = 0x03
local AOB_TICKS = "8B 87 50 0A 00 00 8B 8F 98 09 00 00 8B 15"
local TICKS_OPERAND = 0x0E

---------------------------------------------------------------------------------------
-- Layouts (the same in both executables unless read from code above)
---------------------------------------------------------------------------------------

local U = { STRIDE = 0x490, STATE = 0x8C, TYPE = 0x8E, OWNER = 0x96, UID = 0x98, DYING = 0x2A0,
  TRIBE = 0x2D8, BEHAVIOUR = 0x42A, STATE_OFFSET = 0x614 }
local P = {
  STRIDE = 0x39F4, HAS_KEEP = 0x94, RESOURCES = 0x4D0, LORD = 0x21F8, LORD_UID = 0x21FC,
  AI_TYPE = 0x2300, AI_STATE = 0x2BA4, ATTACK_TROOPS = 0x30F0, TRIBE_IDS = 0x310C,
  TRIBE_UIDS = 0x329C, NERVOUS = 0x3820, REQUESTED = 0x3824, REQUESTED_AMOUNT = 0x3838,
  REQUEST_STATE = 0x384C, ASKER = 0x38E4,
}
local T = { UID = 0x34, STATE = 0x40 }
-- AIC fields live in the AI state object: (character - 1) * 0x2A4 + field.
local AIC = { STRIDE = 0x2A4, MIN_GOODS = 0xA4, SUPPORT_THRESHOLD = 0x1FC }

local GOLD = 15
local LORD_TYPE = 55
local REQUEST_HELP = 2
local MAIN_ARMY = 20
local MAIN_ARMY_SLOTS = { 0xC0, 0xC7 }
local GOLD_MIN_FLOOR = 10       -- a trade minimum below this counts as this for the gold line
local LOAD_GAP = 4000           -- a jump in the tick counter this big is a load

-- Units that are no fighting force: tunnellers, engineers, laddermen, the lord, siege engines.
local NOT_ARMY = { [5] = true, [29] = true, [30] = true, [39] = true, [40] = true, [41] = true,
  [55] = true, [58] = true, [59] = true, [60] = true, [61] = true, [77] = true }
-- aiUnitBehaviourType: 10-20 attack troops (all sent to help), the rest are taken in this
-- order: raiders, patrols, defenders.
local ATTACK_FIRST, ATTACK_LAST = 10, 20
local TAKE_ORDER = { 2, 4, 6, 7, 1 }

---------------------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------------------

local rd32, rd16, rd8 = core.readInteger, core.readSmallInteger, core.readByte
local wr32, wr16 = core.writeInteger, core.writeSmallInteger

local function scan(pattern, purpose)
  local ok, address = pcall(core.AOBScan, pattern)
  if not ok or address == nil then
    error(MODULE_NAME .. ": could not find " .. purpose)
  end
  return address
end

local function expectBytes(address, bytes, purpose)
  for index, byte in ipairs(bytes) do
    if (rd8(address + index - 1) & 0xFF) ~= byte then
      error(string.format("%s: %s at 0x%X is not the code this module knows", MODULE_NAME, purpose,
        address))
    end
  end
end

local function readOperand(base, site, purpose)
  expectBytes(base + site[1], site[2], purpose)
  return rd32(base + site[1] + #site[2])
end

local function readCallTarget(base, offset, purpose)
  expectBytes(base + offset, { 0xE8 }, purpose)
  return base + offset + 5 + rd32(base + offset + 1)
end

local function setting(config, group, name)
  local section = config[group]
  if type(section) == "table" and section[name] ~= nil then
    return section[name]
  end
  return DEFAULTS[group][name]
end

local function number(value, low, high)
  value = math.tointeger(math.floor(tonumber(value) or 0)) or 0
  if value < low then return low end
  if value > high then return high end
  return value
end

---------------------------------------------------------------------------------------
-- State
---------------------------------------------------------------------------------------

local G = {}             -- addresses, filled by enable
local F = {}             -- the game's functions, exposed to lua
local O = {}             -- options
local toppedUp = {}      -- per AI player: the ally it already topped its relief army up for
local lastTick = nil
local broken = false

local function diag(fmt, ...)
  if O.log then
    log(INFO, MODULE_NAME .. ": " .. string.format(fmt, ...))
  end
end

local function player(p) return G.players + p * P.STRIDE end
local function unit(id) return G.units + id * U.STRIDE end
local function tribe(id) return G.tribes + id * G.tribeStride end

local function team(p) return rd32(G.teams + p * 4) end
local function isAI(p) return rd32(player(p) + P.AI_TYPE) ~= 0 end
local function nervous(p) return rd32(player(p) + P.NERVOUS) ~= 0 end
local function gold(p) return rd32(player(p) + P.RESOURCES + GOLD * 4) end

-- Same non-zero team: team 0 means allied with nobody.
local function allies(a, b)
  return a ~= b and team(a) ~= 0 and team(a) == team(b)
end

local function aic(p, field)
  return rd32(G.aiState + (rd32(player(p) + P.AI_TYPE) - 1) * AIC.STRIDE + field)
end

local function lordAlive(p)
  local id = rd32(player(p) + P.LORD)
  if id <= 0 then return false end
  local u = unit(id)
  return rd16(u + U.STATE) == 2 and rd16(u + U.TYPE) == LORD_TYPE and rd16(u + U.DYING) == 0
    and rd32(u + U.UID) == rd32(player(p) + P.LORD_UID)
end

---------------------------------------------------------------------------------------
-- 1 + 2: goods and gold
---------------------------------------------------------------------------------------

local function clearRequest(p, from)
  wr16(player(p) + P.REQUESTED + from * 2, 0)
  wr16(player(p) + P.REQUESTED_AMOUNT + from * 2, 0)
end

local function shareGold(h, r)
  local line = O.goldFactor * math.max(aic(h, AIC.MIN_GOODS), GOLD_MIN_FLOOR)
  local have = gold(h)
  if have < line or have <= gold(r) then return end
  local gift = (have - line) * O.goldShare // 100
  if gift <= 0 then return end
  wr32(player(h) + P.RESOURCES + GOLD * 4, have - gift)
  wr32(player(r) + P.RESOURCES + GOLD * 4, gold(r) + gift)
  diag("player %d sends player %d %d gold (had %d, keeps at least %d)", h, r, gift, have, line)
end

local function answerRequests(h)
  local base = player(h)
  for r = 1, 8 do
    local resource = rd16(base + P.REQUESTED + r * 2)
    if r ~= h and resource > 0 then
      local amount = rd16(base + P.REQUESTED_AMOUNT + r * 2)
      clearRequest(h, r)
      if allies(h, r) and isAI(r) and lordAlive(r) and amount > 0 then
        if O.goods and resource ~= GOLD and F.enough(G.aiState, h, resource, amount) ~= 0 then
          F.gain(G.buildings, r, resource, amount)
          F.loss(G.buildings, h, resource, amount, 0)
          diag("player %d sends player %d %d of resource %d", h, r, amount, resource)
          for o = 1, 8 do
            if o ~= h and o ~= r and isAI(o) and rd16(player(o) + P.REQUESTED + r * 2) == resource then
              clearRequest(o, r)
            end
          end
        end
        if O.gold then shareGold(h, r) end
      end
    end
  end
end

---------------------------------------------------------------------------------------
-- 3: AI allies come to help each other
---------------------------------------------------------------------------------------

local function needsHelp(r, h)
  return allies(h, r) and isAI(r) and lordAlive(r) and rd32(player(r) + P.HAS_KEEP) ~= 0
    and nervous(r)
end

local function answerHelp(h)
  local base = player(h)
  local state = rd32(base + P.REQUEST_STATE)
  if state == REQUEST_HELP then
    -- An AI asker can only be one this module set up (a human only asks for themselves).
    local asker = rd32(base + P.ASKER)
    if asker >= 1 and asker <= 8 and isAI(asker) and not needsHelp(asker, h) then
      wr32(base + P.REQUEST_STATE, 0)
      diag("player %d stops helping player %d", h, asker)
    end
    return
  end
  if state ~= 0 or rd32(base + P.AI_STATE) ~= 0 or nervous(h) then return end
  if rd32(base + P.ATTACK_TROOPS) < aic(h, AIC.SUPPORT_THRESHOLD) then return end
  for r = 1, 8 do
    if needsHelp(r, h) then
      wr32(base + P.ASKER, r)
      wr32(base + P.REQUEST_STATE, REQUEST_HELP)
      diag("player %d comes to help player %d", h, r)
      return
    end
  end
end

---------------------------------------------------------------------------------------
-- 4: the relief army is at least a share of the whole army
---------------------------------------------------------------------------------------

local function hasMainArmyTroop(h)
  local base = player(h)
  for slot = MAIN_ARMY_SLOTS[1], MAIN_ARMY_SLOTS[2] do
    local id = rd16(base + P.TRIBE_IDS + slot * 2)
    if id > 0 and rd16(tribe(id) + T.STATE) == 2
        and rd32(tribe(id) + T.UID) == rd32(base + P.TRIBE_UIDS + slot * 4) then
      return true
    end
  end
  return false
end

local function topUp(h)
  local base = player(h)
  if rd32(base + P.REQUEST_STATE) ~= REQUEST_HELP then
    toppedUp[h] = nil
    return
  end
  local asker = rd32(base + P.ASKER)
  if toppedUp[h] == asker or asker < 1 or asker > 8 or not allies(h, asker) or not lordAlive(asker) then
    return
  end
  toppedUp[h] = asker
  if not hasMainArmyTroop(h) then return end

  local army, sent, spare = 0, 0, {}
  for _, b in ipairs(TAKE_ORDER) do spare[b] = {} end
  local count = rd32(G.unitsThis)
  for index = 1, count - 1 do
    local u = unit(index)
    if rd16(u + U.OWNER) == h and rd16(u + U.STATE) == 2 and rd16(u + U.DYING) == 0
        and not NOT_ARMY[rd16(u + U.TYPE)] then
      local b = rd16(u + U.BEHAVIOUR)
      if b >= ATTACK_FIRST and b <= ATTACK_LAST then
        army, sent = army + 1, sent + 1
      elseif spare[b] ~= nil then
        army = army + 1
        table.insert(spare[b], index)
      end
    end
  end

  local need = (army * O.armyShare + 99) // 100 - sent
  local moved = 0
  for _, b in ipairs(TAKE_ORDER) do
    for _, index in ipairs(spare[b]) do
      if moved >= need then break end
      local old = rd16(unit(index) + U.TRIBE)
      if old > 0 then F.removeFromTribe(G.tribes, index, old) end
      F.addToItsTribe(G.aiState, index, MAIN_ARMY)
      moved = moved + 1
    end
  end
  if moved > 0 then
    F.clearRally(G.aiState, h)
    F.send(G.aiState, h, asker)
  end
  diag("player %d helps player %d: army %d, attack troops %d, %d more sent", h, asker, army, sent, moved)
end

---------------------------------------------------------------------------------------
-- Per AI player, once per AI cycle
---------------------------------------------------------------------------------------

local function update(h)
  local tick = rd32(G.ticks)
  if lastTick == nil or tick < lastTick or tick - lastTick > LOAD_GAP then
    toppedUp = {}
  end
  lastTick = tick
  if h < 1 or h > 8 or not isAI(h) or not lordAlive(h) then return end
  if O.goods or O.gold then answerRequests(h) end
  if O.help then answerHelp(h) end
  if O.army then topUp(h) end
end

local STUB = [[
mov eax,[esp+4]
mov [PLAYER],eax
mov [THIS],ecx
call PAD
jmp ORIGINAL_TARGET
]]

---------------------------------------------------------------------------------------
-- Enable
---------------------------------------------------------------------------------------

local function resolve()
  local calls = scan(AOB_CALLS, "the AI's per player update")
  G.site = calls + CALL_HOOK
  G.original = readCallTarget(calls, CALL_HOOK, "the AI's food purchase plan call")

  local its = scan(AOB_ADD_TO_ITS_TRIBE, "where the AI puts a unit in its troop")
  G.units = readOperand(its, ITS_UNIT_OWNER, "the unit array") - U.OWNER
  G.unitsThis = G.units - U.STATE_OFFSET
  G.players = readOperand(its, ITS_AI_TYPE, "the player array") - P.AI_TYPE
  G.tribes = readOperand(its, ITS_TRIBES, "the troop array")
  local remove = scan(AOB_REMOVE_FROM_TRIBE, "removeUnitFromTribe")
  G.tribeStride = readOperand(remove, REMOVE_STRIDE, "the troop size")

  local gift = scan(AOB_GIFT, "how an AI ally sends goods")
  G.buildings = readOperand(gift, GIFT_BUILDINGS, "the buildings state")
  local gain = readCallTarget(gift, GIFT_GAIN, "processResourceGain")
  local loss = readCallTarget(gift, GIFT_LOSS, "processResourceLoss")
  local enough = scan(AOB_ENOUGH, "the AI's trade minimum test")

  local send = scan(AOB_SEND, "how an AI answers a call for help")
  if readOperand(send, SEND_STATE, "the help request") ~= G.players + P.REQUEST_STATE
      or readOperand(send, SEND_ASKER, "the help request") ~= G.players + P.ASKER then
    error(MODULE_NAME .. ": the player array is not laid out as the module expects")
  end
  local clearRally = readCallTarget(send, SEND_CLEAR_RALLY, "clearRallyFlagOnAllAIAttackTribes")
  local sendTroops = readCallTarget(send, SEND_TROOPS, "sendUnitsToPlayerIDsKeepIfPossible")

  G.teams = rd32(scan(AOB_TEAMS, "the team table") + TEAMS_OPERAND)
  G.ticks = rd32(scan(AOB_TICKS, "the game tick counter") + TICKS_OPERAND)

  F.enough = core.exposeCode(enough, 4, 1)
  F.gain = core.exposeCode(gain, 4, 1)
  F.loss = core.exposeCode(loss, 5, 1)
  F.removeFromTribe = core.exposeCode(remove, 3, 1)
  F.addToItsTribe = core.exposeCode(its, 3, 1)
  F.clearRally = core.exposeCode(clearRally, 2, 1)
  F.send = core.exposeCode(sendTroops, 3, 1)
end

local function enable(self, config)
  config = config or {}
  O.goods = setting(config, "goods", "enabled") == true
  O.gold = setting(config, "gold", "enabled") == true
  O.goldFactor = number(setting(config, "gold", "factor"), 1, 10000)
  O.goldShare = number(setting(config, "gold", "share"), 0, 100)
  if O.goldShare == 0 then O.gold = false end
  O.help = setting(config, "help", "enabled") == true
  O.army = setting(config, "army", "enabled") == true
  O.armyShare = number(setting(config, "army", "share"), 0, 100)
  if O.armyShare == 0 then O.army = false end
  O.log = setting(config, "diagnostics", "log") == true
  if not (O.goods or O.gold or O.help or O.army) then
    log(INFO, MODULE_NAME .. ": every part is off")
    return
  end

  local ok, problem = pcall(resolve)
  if not ok then
    log(WARNING, tostring(problem))
    return
  end

  local slots = core.allocate(8, true)
  local pad = core.allocateCode({ 0x90, 0x90, 0x90, 0x90, 0x90, 0xC3 })
  core.detourCode(function(registers)
    if not broken then
      G.aiState = rd32(slots + 4)
      local done, problem = pcall(update, rd32(slots))
      if not done then
        broken = true
        log(WARNING, MODULE_NAME .. ": stopped after an error: " .. tostring(problem))
      end
    end
    return registers
  end, pad, 5)
  local stub = core.allocateAssembly(STUB, {
    PLAYER = slots, THIS = slots + 4, PAD = pad, ORIGINAL_TARGET = G.original,
  })
  self.saved = { address = G.site, bytes = core.readBytes(G.site, 5) }
  core.writeCode(G.site, { 0xE8, core.itob(core.getRelativeAddress(G.site, stub, -5)) })
  log(INFO, string.format("%s: on (goods %s, gold %s, help %s, army %s%%); hooked 0x%X",
    MODULE_NAME, O.goods and "on" or "off", O.gold and "on" or "off", O.help and "on" or "off",
    O.army and O.armyShare or 0, G.site))
end

local function disable(self, config)
  if self.saved ~= nil then
    core.writeCode(self.saved.address, self.saved.bytes)
    self.saved = nil
  end
end

return {
  enable = enable,
  disable = disable,
}
