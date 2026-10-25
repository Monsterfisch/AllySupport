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
     Statistics (goods sent / received by value) are added as the game adds them. A weak ally
     (aiStrengthFeeling 1) gets up to half of what it asked for if the giver can spare that by
     going down to half its trade minimum.
  2. Gold: a lord asked for goods that holds at least 100 x its MinimumGoodsRequiredAfterTrade in
     gold also sends the asker a share of the gold above that line.
  2b. Asking for gold: a lord that wants goods it cannot afford asks its allies (player and
     AIs) for the gold it is short, through requestGoods with resource 15. The player's ally
     screen shows and sends gold already; AI allies send it if they stay above their gold line
     (see 2), a weak ally up to half going down to half the line.
  3. Help: an idle AI that is not nervous and has its AIC's support threshold of attack troops
     answers a nervous AI ally the way it answers the player: requestStateUnk = 2,
     playerID_askerUnk = the ally. The AI's own state machine then sends the attack troops to
     that keep every cycle. The help ends once the ally is out of danger (not nervous) and
     the minimum stay (6 in-game months by default) is over, or at once when, by the setting,
     the ally feels strong again (aiStrengthFeeling 2, set monthly by updateAIStrengthState) or
     the helper's own attack army is full (the game's test before it attacks). The game leaves
     the troops where they are when a help ends, so they are sent home with
     sendUnitsToPlayerIDsKeepIfPossible(helper, helper); the lord then waits 3 months or for its
     own attack before it helps again.
  4. Army share: the game sends every attack troop to help. Whenever an AI is helping anyone
     (player or AI), 25% of its attack army (behaviours 10-20) is moved into a troop of its own
     (createTribeForPlayer) that the AI has not registered in aiTribeIDs and so never orders,
     and sent back to its own camp; the other 75% go. Jobs (engineers, laddermen, tunnellers,
     siege crews) stay home first. Recruits joining the attack army while it helps are split
     the same way. When the help ends the kept troops go back into the AI's own troops
     (addUnitToItsTribe). Nothing is written to the save: after a load, attack units in
     troops the AI has not registered go back to the AI and are split again.
  5. Gates: a castle under attack keeps its gates shut, so the relief stands outside. While an
     AI helps, every gatehouse of the castle it helps is watched in the game's own gate logic
     (updateGateDrawBridgeOpenCloseLogic, per gatehouse per tick, where the open / close part
     for a gate nobody has captured starts). Every few ticks the module looks for the helper's
     troops within a few tiles of the gate on the outside (the area map, built with every gate
     shut, tells inside from outside the keep's walls). If there are any, the gate is opened
     the way the game opens it (+0x2A3 = 0xB "opening", applyGateOrDrawbridgeOpenCloseChange
     for a drawbridge in front), the game's own close check is skipped, and their troop is
     ordered to the keep. Once nobody waits, the game's own logic takes over again and shuts
     it. When the help ends, the gate opens the same way for the helper's troops leaving.
]]

local MODULE_NAME = "ally-support"

local DEFAULTS = {
  goods = { enabled = true, weak = true },
  gold = { enabled = true, factor = 100, share = 25, ask = true },
  help = { enabled = true, months = 6, recall = "strong" },
  army = { enabled = true, share = 75 },
  gates = { enabled = true },
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
local ITS_ADD_TO_TRIBE = 0x44
local AOB_CREATE_TRIBE = "53 55 8B 6C 24 0C 56 57 BF ? ? 00 00 2B FD 33 DB 3B FB 7E"
local AOB_MOVE = "83 EC 34 33 C0 55 8B 6C 24 44 57 8B 7C 24 44 3B F8 89 4C 24 08 89 44 24 18"

-- ProcessAllyRequestingGoods, the branch where an AI ally sends the player what they asked for.
local AOB_GIFT = "53 8B 5C 24 1C 55 53 56 B9 ? ? ? ? E8 ? ? ? ? 8B 6C 24 1C 55 57 53 B9 ? ? ? ? E8 ? ? ? ? 6A 00 55 57 56 B9 ? ? ? ? E8"
local GIFT_BUILDINGS = { 0x19, { 0xB9 } }
local GIFT_GAIN = 0x1E
local GIFT_LOSS = 0x2D
local GIFT_GAME_STATE = { 0x35, { 0xB9 } }
local GIFT_SELL_PRICE = 0x3A
local GIFT_RECEIVED = { 0x3F, { 0x01, 0x04, 0x9D } }   -- add [receiver*4 + goods received], eax
local GIFT_SENT = { 0x4E, { 0x8D, 0x1C, 0xB5 } }       -- lea ebx, [sender*4 + goods sent]

-- buyRequiredGoods: the wish list and the price check before buying.
local AOB_ACQUIRE = "8B 3C 8D ? ? ? ? 85 FF 74"
local ACQUIRE_LIST = { 0x00, { 0x8B, 0x3C, 0x8D } }
local AOB_BUY = "57 56 55 B9 ? ? ? ? E8 ? ? ? ? 39 83 ? ? ? ? 8B 4C 24 10 7D"
local BUY_PRICE = 0x08
-- AICState::requestGoods(player, resource, amount)
local AOB_REQUEST_GOODS = "51 8B 54 24 08 8B C2 69 C0 F4 39 00 00 83 B8 ? ? ? ? 00 89 0C 24 0F 84"

-- AICState::isResourceLargerOrEqualThanMinimumGoodsRequiredAfterTrade(player, resource, amount)
local AOB_ENOUGH = "8B 44 24 04 8B D0 69 D2 F4 39 00 00 8B 92 ? ? ? ? 85 D2 75 06 8D 42 01 C2 0C 00"

-- updateAIPlayerState: requestStateUnk 2 -> clearRallyFlagOnAllAIAttackTribes,
-- sendUnitsToPlayerIDsKeepIfPossible(player, playerID_askerUnk).
local AOB_SEND = "8B 87 ? ? ? ? 83 F8 01 74 ? 83 F8 02 75 ? 8B 87 ? ? ? ? 50 B9"
local SEND_STATE = { 0x00, { 0x8B, 0x87 } }
local SEND_ASKER = { 0x10, { 0x8B, 0x87 } }
local SEND_TROOPS = 0x37
-- sendUnitsToPlayerIDsKeepIfPossible reads the helper's own camp: y, then x.
local CAMP_Y = { 0x16, { 0x8B, 0x9E } }
local CAMP_X = { 0x1D, { 0x8B, 0xBE } }

local AOB_TEAMS = "8B 0C 85 ? ? ? ? 8B 44 24 30 3B 0C 85 ? ? ? ?"
local TEAMS_OPERAND = 0x03
local AOB_TICKS = "8B 87 50 0A 00 00 8B 8F 98 09 00 00 8B 15"
local TICKS_OPERAND = 0x0E
-- processSingleTimeTick copies the date: mov ecx, [year] / mov edx, [month].
local AOB_DATE = "8B 0D ? ? ? ? 8B 15 ? ? ? ? 89 0D ? ? ? ? 8B CE 89 15"
local DATE_YEAR, DATE_MONTH = 0x02, 0x08

-- updateGateDrawBridgeOpenCloseLogic, after the capture part: movzx eax, word [edi + enemy timer].
-- Offsets below are from the hook site (pattern + 1).
local AOB_GATE = "C3 0F B7 87 ? ? ? ? 66 3B C2 7E 21 8B CD 69 C9 F4 39 00 00 83 C0 FF 39 91"
local GATE_SITE, GATE_SITE_SIZE = 0x01, 7
local GATE_TIMER = { 0x00, { 0x0F, 0xB7, 0x87 } }
local GATE_DONE = { 0x79, { 0x0F, 0x8C } }       -- jl to the function's end
local GATE_LINK = { 0x17D, { 0x80, 0xBF } }      -- cmp byte [edi + gate link state], 2
local GATE_STATE = { 0x188, { 0xC6, 0x87 } }     -- mov byte [edi + gate state], 0xB
local GATE_APPLY = 0x196

-- GameState::canNavigateFromKeepToKeep: the area map. The tile map: rows and y of a tile.
local AOB_KEEP_TO_KEEP = "56 8B 74 24 08 8B C6 69 C0 F4 39 00 00 03 C1 83 B8 ? ? ? ? 00 75 09 B8 01 00 00 00"
local K2K_AREA = { 0x42, { 0x0F, 0xB7, 0x04, 0x4D } }
local AOB_TILE_FLAGS = "F7 04 9D ? ? ? ? 00 01 00 00"
local TILE_FLAGS_OPERAND = 0x03

---------------------------------------------------------------------------------------
-- Layouts (the same in both executables unless read from code above)
---------------------------------------------------------------------------------------

local U = { STRIDE = 0x490, STATE = 0x8C, TYPE = 0x8E, OWNER = 0x96, UID = 0x98, X = 0xC4, Y = 0xC6,
  TILE = 0xD4, DYING = 0x2A0, TRIBE = 0x2D8, BEHAVIOUR = 0x42A, STATE_OFFSET = 0x614 }
local B = { STRIDE = 0x32C, TYPE = 0xD2, OWNER = 0xD6, X = 0xEE, Y = 0xF0, SIZE = 0xF8, LINK = 0x2A2,
  STATE = 0x2A3, TIMER = 0x2C0, ARRAY = 0x14, MAX = 2000 }
local MAP = { FLAGS = 0x165160, Y_OF_TILE = 0x742B90, ROWS = 0x8A40F8, AREA = 0x363ED0 }
local P = {
  STRIDE = 0x39F4, HAS_KEEP = 0x94, KEEP_TILE = 0x1E0, CAMP_X = 0x1D8, CAMP_Y = 0x1DC,
  RESOURCES = 0x4D0,
  LORD = 0x21F8, LORD_UID = 0x21FC,
  AI_TYPE = 0x2300, AI_STATE = 0x2BA4, ATTACK_TROOPS = 0x30F0, TRIBE_IDS = 0x310C,
  TRIBE_UIDS = 0x329C, NERVOUS = 0x3820, REQUESTED = 0x3824, REQUESTED_AMOUNT = 0x3838,
  REQUEST_STATE = 0x384C, ASKER = 0x38E4, TO_ACQUIRE = 0x2A70, STRENGTH_FEELING = 0x30F4, ATTACK_ENGINEERS = 0x2BA8,
  WAVE_EXTRA = 0x38A0,
}
local T = { UID = 0x34, STATE = 0x40 }
-- AIC fields live in the AI state object: (character - 1) * 0x2A4 + field.
local AIC = { STRIDE = 0x2A4, MIN_GOODS = 0xA4, ATTACK_FORCE = 0x1F4, SUPPORT_THRESHOLD = 0x1FC }

local GOLD = 15
local LORD_TYPE = 55
local REQUEST_HELP = 2
local WEAK, STRONG = 1, 2       -- aiStrengthFeeling: 0 normal, 1 weak, 2 strong
local HELP_PAUSE_MONTHS = 3     -- after its help ends, a lord waits this long (or for its own
                                -- attack) before it helps again
local GOLD_MIN_FLOOR = 10       -- a trade minimum below this counts as this for the gold line
local GOLD_ASK_MONTHS = 1       -- a lord asks for gold at most this often
local GOLD_ASK_MAX = 30000      -- the request slot is a short
local LOAD_GAP = 4000           -- a jump in the tick counter this big is a load

-- aiUnitBehaviourType 10-20: the attack army, the troops the game sends to help.
local ATTACK_FIRST, ATTACK_LAST = 10, 20
-- No use defending an ally's castle, so these stay home first: tunnellers, engineers,
-- laddermen, siege engines.
local STAY_FIRST = { [5] = true, [29] = true, [30] = true, [39] = true, [40] = true, [41] = true,
  [58] = true, [59] = true, [60] = true, [61] = true, [77] = true }

-- Large and small stone gatehouses, wooden gates.
local GATEHOUSE = { [45] = true, [46] = true, [47] = true, [48] = true }
local GATE_CLOSED, GATE_OPENING = 2, 0xB
local GATE_RANGE = 5            -- tiles beyond the gatehouse's edge that count as at the door
local GATE_CHECK_TICKS = 8      -- how often a watched gate looks for troops at its door
local ORDER_TICKS = 40          -- a troop at the door is ordered inside at most this often

---------------------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------------------

local rd32, rd16, rd8 = core.readInteger, core.readSmallInteger, core.readByte
local wr32, wr16, wr8 = core.writeInteger, core.writeSmallInteger, core.writeByte

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
local kept = {}         -- per AI player: { id, uid } of the troop kept home while it helps
local swept = {}        -- per AI player: troops checked after a load
local visitors = {}     -- per helped player: { [helper] = true } whose troops may use its gates
local visitorUnits = {} -- per helper: its attack units sent to help
local gates = {}        -- per watched gatehouse id: { owner, next, hold }
local ordered = {}      -- per troop id: tick it was last ordered inside
local helpSince = {}    -- per AI player helping an AI: { asker, month } the help started
local pause = {}        -- per AI player: month its last help ended
local goldAsked = {}    -- per AI player: month it last asked for gold
local wasHelping = {}   -- per AI player: it was helping someone at its last cycle
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
local function building(id) return G.buildingArray + id * B.STRIDE end

local function area(tile)
  if tile == nil or tile <= 0 then return 0 end
  return rd16(G.area + tile * 2) & 0xFFFF
end

local function tileXY(tile)
  local y = rd16(G.yOfTile + tile * 2)
  return tile - rd32(G.rows + y * 12), y
end

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

-- The gold a lord always keeps: the "rich" line, a multiple of its AIC trade minimum.
local function goldLine(h) return O.goldFactor * math.max(aic(h, AIC.MIN_GOODS), GOLD_MIN_FLOOR) end

local function shareGold(h, r)
  local line = goldLine(h)
  local have = gold(h)
  if have < line or have <= gold(r) then return end
  local gift = (have - line) * O.goldShare // 100
  if gift <= 0 then return end
  wr32(player(h) + P.RESOURCES + GOLD * 4, have - gift)
  wr32(player(r) + P.RESOURCES + GOLD * 4, gold(r) + gift)
  diag("player %d sends player %d %d gold (had %d, keeps at least %d)", h, r, gift, have, line)
end

-- Moves goods the way the game does when an AI ally sends the player what they asked for,
-- end-of-game statistics (goods sent / received, by value) included.
local function sendGoods(h, r, resource, amount)
  F.gain(G.buildings, r, resource, amount)
  F.loss(G.buildings, h, resource, amount, 0)
  local value = F.sellPrice(G.gameState, h, resource, amount)
  wr32(G.goodsReceived + r * 4, rd32(G.goodsReceived + r * 4) + value)
  wr32(G.goodsSent + h * 4, rd32(G.goodsSent + h * 4) + value)
end

-- How much h sends of a request: all of it if it keeps its AIC trade minimum afterwards (the
-- game's own test). A weak ally gets up to half of it if h can spare that by going down to half
-- its trade minimum.
local function shipment(h, r, resource, amount)
  if F.enough(G.aiState, h, resource, amount) ~= 0 then return amount end
  if not O.goodsWeak or rd32(player(r) + P.STRENGTH_FEELING) ~= WEAK then return 0 end
  local spare = rd32(player(h) + P.RESOURCES + resource * 4) - (aic(h, AIC.MIN_GOODS) + 1) // 2
  return math.max(0, math.min(amount // 2, spare))
end

-- Gold moves as the game moves it when the player sends gold (straight between treasuries,
-- counted at face value in the statistics).
local function sendGold(h, r, amount)
  wr32(player(h) + P.RESOURCES + GOLD * 4, gold(h) - amount)
  wr32(player(r) + P.RESOURCES + GOLD * 4, gold(r) + amount)
  wr32(G.goodsReceived + r * 4, rd32(G.goodsReceived + r * 4) + amount)
  wr32(G.goodsSent + h * 4, rd32(G.goodsSent + h * 4) + amount)
end

-- Gold asked for: all of it if h stays above its gold line, a weak ally up to half of it if h
-- can spare that by going down to half its line.
local function goldShipment(h, r, amount)
  local line = goldLine(h)
  if gold(h) - amount >= line then return amount end
  if not O.goodsWeak or rd32(player(r) + P.STRENGTH_FEELING) ~= WEAK then return 0 end
  return math.max(0, math.min(amount // 2, gold(h) - (line + 1) // 2))
end

local function answerRequests(h)
  local base = player(h)
  for r = 1, 8 do
    local resource = rd16(base + P.REQUESTED + r * 2)
    if r ~= h and resource > 0 then
      local amount = rd16(base + P.REQUESTED_AMOUNT + r * 2)
      clearRequest(h, r)
      if allies(h, r) and isAI(r) and lordAlive(r) and amount > 0 then
        local send = 0
        if resource == GOLD then
          if O.goldAsk then send = goldShipment(h, r, amount) end
        elseif O.goods then
          send = shipment(h, r, resource, amount)
        end
        if send > 0 then
          if resource == GOLD then sendGold(h, r, send) else sendGoods(h, r, resource, send) end
          diag("player %d sends player %d %d of %d asked of resource %d", h, r, send, amount, resource)
          for o = 1, 8 do
            if o ~= h and o ~= r and isAI(o) and rd16(player(o) + P.REQUESTED + r * 2) == resource then
              clearRequest(o, r)
            end
          end
        end
        if O.gold and resource ~= GOLD then shareGold(h, r) end
      end
    end
  end
end

---------------------------------------------------------------------------------------
-- 3: AI allies come to help each other
---------------------------------------------------------------------------------------

local function canBeHelped(r, h)
  return allies(h, r) and isAI(r) and lordAlive(r) and rd32(player(r) + P.HAS_KEEP) ~= 0
end

local function needsHelp(r, h) return canBeHelped(r, h) and nervous(r) end

local function months() return rd32(G.year) * 12 + rd32(G.month) end
local function strong(r) return rd32(player(r) + P.STRENGTH_FEELING) == STRONG end

-- The game's own "ready to attack" test (aiShouldAttackOrWaitForTeamCoordination): attack troops
-- without engineers reach AttForceBase plus this wave's random extra.
local function armyFull(h)
  local base = player(h)
  return rd32(base + P.ATTACK_TROOPS) - rd32(base + P.ATTACK_ENGINEERS)
    >= aic(h, AIC.ATTACK_FORCE) + rd32(base + P.WAVE_EXTRA)
end

local function answerHelp(h)
  local base = player(h)
  local state = rd32(base + P.REQUEST_STATE)
  if state == REQUEST_HELP then
    -- An AI asker can only be one this module set up (a human only asks for themselves).
    local asker = rd32(base + P.ASKER)
    if asker >= 1 and asker <= 8 and isAI(asker) then
      local since = helpSince[h]
      if since == nil or since.asker ~= asker then
        since = { asker = asker, month = months() }    -- after a load the stay starts again
        helpSince[h] = since
      end
      -- Stay the minimum stay, and longer while the ally is still in danger - unless, by the
      -- setting, the ally feels strong again or the helper's own attack army is full: that
      -- calls them home at once. (The game re-checks "in danger" once a month, and a weak lord
      -- can stay in danger for good, so it must not hold up the early recall.)
      local stayed = months() - since.month
      local early = (O.recall == "army" and armyFull(h)) or (O.recall ~= "army" and strong(asker))
      if not canBeHelped(asker, h) or early or (stayed >= O.stayMonths and not nervous(asker)) then
        wr32(base + P.REQUEST_STATE, 0)
        helpSince[h] = nil
        pause[h] = months()
        diag("player %d stops helping player %d after %d months (%s)", h, asker, stayed,
          early and (O.recall == "army" and "its army is ready" or "the ally is strong") or "stay over")
      end
    end
    return
  end
  helpSince[h] = nil
  if rd32(base + P.AI_STATE) ~= 0 then pause[h] = nil end     -- it has set out to attack
  if pause[h] ~= nil and months() - pause[h] < HELP_PAUSE_MONTHS then return end
  if state ~= 0 or rd32(base + P.AI_STATE) ~= 0 or nervous(h) then return end
  if rd32(base + P.ATTACK_TROOPS) < aic(h, AIC.SUPPORT_THRESHOLD) then return end
  for r = 1, 8 do
    if needsHelp(r, h) then
      wr32(base + P.ASKER, r)
      wr32(base + P.REQUEST_STATE, REQUEST_HELP)
      helpSince[h] = { asker = r, month = months() }
      diag("player %d comes to help player %d", h, r)
      return
    end
  end
end

---------------------------------------------------------------------------------------
-- 2b: AI lords ask their allies for gold
---------------------------------------------------------------------------------------

-- When a lord wants goods (resourcesToAcquireArray, what buyRequiredGoods buys) and cannot
-- afford even the cheapest of them, it asks its allies - the player and AIs alike - for the
-- gold it is short, with the game's own requestGoods. At most once every GOLD_ASK_MONTHS.
local function askForGold(h)
  local now = months()
  local last = goldAsked[h]
  if last ~= nil and last <= now and now - last < GOLD_ASK_MONTHS then return end
  local base = player(h)
  local total, cheapest = 0, nil
  for resource = 0, 24 do
    local want = rd32(base + P.TO_ACQUIRE + resource * 4)
    if want > 0 and resource ~= GOLD then
      local price = F.buyPrice(G.gameState, h, resource, want)
      total = total + price
      if cheapest == nil or price < cheapest then cheapest = price end
    end
  end
  local have = gold(h)
  if cheapest == nil or have >= cheapest then return end
  local amount = math.min(total - have, GOLD_ASK_MAX)
  if amount <= 0 then return end
  F.requestGoods(G.aiState, h, GOLD, amount)
  goldAsked[h] = now
  diag("player %d asks its allies for %d gold (has %d, wants goods for %d)", h, amount, have, total)
end

---------------------------------------------------------------------------------------
-- 4: only a share of the attack army goes to help, the rest stays home
---------------------------------------------------------------------------------------

local function tribeAlive(k)
  return k ~= nil and k.id > 0 and rd16(tribe(k.id) + T.STATE) == 2 and rd32(tribe(k.id) + T.UID) == k.uid
end

-- Every troop the AI has registered, by tribe id.
local function registeredTribes(h)
  local list = {}
  local base = player(h)
  for slot = 0, 199 do
    local id = rd16(base + P.TRIBE_IDS + slot * 2)
    if id > 0 and rd32(tribe(id) + T.UID) == rd32(base + P.TRIBE_UIDS + slot * 4) then
      list[id] = true
    end
  end
  return list
end

-- Calls fn(index, unitAddress, behaviour) for every living attack army unit of h.
local function eachAttackUnit(h, fn)
  local count = rd32(G.unitsThis)
  for index = 1, count - 1 do
    local u = unit(index)
    if rd16(u + U.OWNER) == h and rd16(u + U.STATE) == 2 and rd16(u + U.DYING) == 0 then
      local b = rd16(u + U.BEHAVIOUR)
      if b >= ATTACK_FIRST and b <= ATTACK_LAST then fn(index, u, b) end
    end
  end
end

local function giveBack(index, from, behaviour)
  if from > 0 then F.removeFromTribe(G.tribes, index, from) end
  F.addToItsTribe(G.aiState, index, behaviour)
end

-- After a load the module knows nothing of the troops it kept home. The AI keeps every attack
-- unit in a troop it registered, so attack units in an unregistered troop go back to the AI.
local function sweep(h)
  local registered = registeredTribes(h)
  local moved = 0
  eachAttackUnit(h, function(index, u, b)
    local id = rd16(u + U.TRIBE)
    if id > 0 and not registered[id] then
      giveBack(index, id, b)
      moved = moved + 1
    end
  end)
  if moved > 0 then diag("player %d: %d units back in the AI's own troops after loading", h, moved) end
end

local function release(h)
  local k = kept[h]
  kept[h] = nil
  if not tribeAlive(k) then return end
  local moved = 0
  eachAttackUnit(h, function(index, u, b)
    if rd16(u + U.TRIBE) == k.id then
      giveBack(index, k.id, b)
      moved = moved + 1
    end
  end)
  diag("player %d stops helping: %d kept troops back in its army", h, moved)
end

local function keepHome(h)
  local base = player(h)
  local asker = rd32(base + P.ASKER)
  if rd32(base + P.REQUEST_STATE) ~= REQUEST_HELP or asker < 1 or asker > 8
      or not allies(h, asker) or not lordAlive(asker) then
    release(h)
    return
  end

  local k = kept[h]
  if not tribeAlive(k) then k = nil end
  local registered = registeredTribes(h)
  local total, home, jobs, fighters = 0, 0, {}, {}
  eachAttackUnit(h, function(index, u, b)
    total = total + 1
    local id = rd16(u + U.TRIBE)
    if k ~= nil and id == k.id then
      home = home + 1
    elseif id > 0 and registered[id] then
      table.insert(STAY_FIRST[rd16(u + U.TYPE)] and jobs or fighters, { index = index, tribe = id })
    end
  end)

  local need = total - (total * O.armyShare + 99) // 100 - home
  if need <= 0 then return end
  if k == nil then
    local id = F.createTribe(G.tribes, h)
    if id == nil or id <= 0 then return end
    k = { id = id, uid = rd32(tribe(id) + T.UID) }
    kept[h] = k
  end
  local moved = 0
  for _, list in ipairs({ jobs, fighters }) do
    for _, entry in ipairs(list) do
      if moved >= need then break end
      F.removeFromTribe(G.tribes, entry.index, entry.tribe)
      F.addToTribe(G.tribes, entry.index, k.id)
      moved = moved + 1
    end
  end
  F.move(G.tribes, k.id, rd32(base + P.CAMP_X), rd32(base + P.CAMP_Y), 0, 0, 0)
  diag("player %d helps player %d: attack army %d, %d more kept home (%d in all)", h, asker, total,
    moved, home + moved)
end

---------------------------------------------------------------------------------------
-- 5: the helped castle opens its gate for the relief
---------------------------------------------------------------------------------------

-- The castle h is helping right now, or nil.
local function helping(h)
  local base = player(h)
  local asker = rd32(base + P.ASKER)
  if rd32(base + P.REQUEST_STATE) == REQUEST_HELP and asker >= 1 and asker <= 8 and allies(h, asker)
      and lordAlive(asker) then
    return asker
  end
  return nil
end

local function keepArea(a) return area(rd32(player(a) + P.KEEP_TILE)) end

local function inside(u, a) return area(rd32(u + U.TILE)) == keepArea(a) end

-- Where relief troops go once inside: the helped lord's camp if it lies within the keep's walls,
-- else the keep's own tile.
local function insideSpot(a)
  local base = player(a)
  local x, y = rd32(base + P.CAMP_X), rd32(base + P.CAMP_Y)
  if x > 0 and y > 0 and x < 400 and y < 400 and area(rd32(G.rows + y * 12) + x) == keepArea(a) then
    return x, y
  end
  return tileXY(rd32(base + P.KEEP_TILE))
end

local function watch(a, on)
  if on then
    local count = math.min(rd32(G.buildings), B.MAX)
    for id = 1, count - 1 do
      local b = building(id)
      if gates[id] == nil and rd16(b + B.OWNER) == a and GATEHOUSE[rd16(b + B.TYPE)] then
        gates[id] = { owner = a, next = 0, hold = false }
        wr8(G.gateFlags + id, 1)
      end
    end
  else
    for id, g in pairs(gates) do
      if g.owner == a then
        gates[id] = nil
        wr8(G.gateFlags + id, 0)
      end
    end
  end
end

-- Per AI cycle: which castles' gates h's troops may use, and which of its troops those are.
local function watchGates(h)
  local a = helping(h)
  if a ~= nil and keepArea(a) ~= 0 then
    local k = kept[h]
    local units = {}
    eachAttackUnit(h, function(index, u)
      if k == nil or rd16(u + U.TRIBE) ~= k.id then units[#units + 1] = index end
    end)
    visitorUnits[h] = units
    visitors[a] = visitors[a] or {}
    visitors[a][h] = true
    watch(a, true)
    -- The game sends the relief to the gate again every cycle; troops already in stay in.
    local x, y = insideSpot(a)
    local done = {}
    for _, index in ipairs(units) do
      local u = unit(index)
      local t = rd16(u + U.TRIBE)
      if t > 0 and not done[t] and inside(u, a) then
        done[t] = true
        F.move(G.tribes, t, x, y, 0, 0, 0)
      end
    end
  end
  -- Castles h no longer helps stay watched while its troops are still inside, so they can leave.
  for v, helpers in pairs(visitors) do
    if helpers[h] and v ~= a then
      local still = false
      if keepArea(v) ~= 0 and allies(h, v) then
        local units = {}
        eachAttackUnit(h, function(index, u)
          units[#units + 1] = index
          if inside(u, v) then still = true end
        end)
        if a == nil then visitorUnits[h] = units end
      end
      if not still then
        helpers[h] = nil
        if next(helpers) == nil then
          visitors[v] = nil
          watch(v, false)
        end
      end
    end
  end
end

-- Per watched gatehouse per tick, from the game's gate logic: 1 = hold it open and skip the
-- game's own open / close check.
local function gateCheck(id)
  local g = gates[id]
  if g == nil then
    wr8(G.gateFlags + id, 0)
    return 0
  end
  local tick = rd32(G.ticks)
  if tick >= g.next or g.next - tick > GATE_CHECK_TICKS then
    g.next = tick + GATE_CHECK_TICKS
    g.hold = false
    local a = g.owner
    local b = building(id)
    local size = rd32(b + B.SIZE)
    local gx, gy = rd16(b + B.X) + size // 2, rd16(b + B.Y) + size // 2
    local reach = size // 2 + GATE_RANGE
    local x, y
    for h in pairs(visitors[a] or {}) do
      local now = helping(h) == a
      for _, index in ipairs(visitorUnits[h] or {}) do
        local u = unit(index)
        if rd16(u + U.OWNER) == h and rd16(u + U.STATE) == 2 and rd16(u + U.DYING) == 0
            and math.abs(rd16(u + U.X) - gx) <= reach and math.abs(rd16(u + U.Y) - gy) <= reach then
          local isIn = inside(u, a)
          if now and not isIn then
            -- Waiting outside: open up and send their troop in.
            g.hold = true
            local t = rd16(u + U.TRIBE)
            local last = ordered[t]
            if t > 0 and (last == nil or tick - last >= ORDER_TICKS or last > tick) then
              if x == nil then x, y = insideSpot(a) end
              F.move(G.tribes, t, x, y, 0, 0, 0)
              ordered[t] = tick
            end
          elseif not now and isIn then
            -- The help is over and they are on their way out.
            g.hold = true
          end
        end
      end
    end
  end
  if not g.hold then return 0 end
  local b = building(id)
  if (rd8(b + B.LINK) & 0xFF) == GATE_CLOSED then
    wr8(b + B.STATE, GATE_OPENING)
    F.apply(G.buildings, id, 1, 0)
    diag("gate %d of player %d opens for allied troops", id, g.owner)
  end
  return 1
end

---------------------------------------------------------------------------------------
-- Per AI player, once per AI cycle
---------------------------------------------------------------------------------------

local function checkLoad()
  local tick = rd32(G.ticks)
  if lastTick == nil or tick < lastTick or tick - lastTick > LOAD_GAP then
    kept, swept, visitors, visitorUnits, gates, ordered, helpSince = {}, {}, {}, {}, {}, {}, {}
    pause, wasHelping, goldAsked = {}, {}, {}
    if G.gateFlags ~= nil then
      for id = 0, B.MAX - 1 do wr8(G.gateFlags + id, 0) end
    end
  end
  lastTick = tick
end

local function update(h)
  checkLoad()
  if h < 1 or h > 8 or not isAI(h) or not lordAlive(h) then return end
  if O.army and not swept[h] then
    swept[h] = true
    sweep(h)
  end
  if O.goods or O.gold or O.goldAsk then answerRequests(h) end
  if O.goldAsk then askForGold(h) end
  if O.help then answerHelp(h) end
  if O.army then keepHome(h) end
  if O.gates then watchGates(h) end
  -- The game leaves the troops where they are when a help ends (also when the player calls it
  -- off); send them home the way it sends them to an ally's keep.
  local state = rd32(player(h) + P.REQUEST_STATE)
  if wasHelping[h] and state == 0 then
    F.send(G.aiState, h, h)
    diag("player %d's troops go home", h)
  end
  wasHelping[h] = state == REQUEST_HELP
end

local GATE_STUB = [[
cmp ebx,MAX_BUILDINGS
jae original
cmp byte [FLAGS+ebx],0
je original
pushad
mov [CURRENT],ebx
call PAD
popad
cmp dword [HOLD],0
jne skip
original:
movzx eax,word [edi+TIMER]
jmp RESUME
skip:
jmp GATE_END
]]

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
  G.gameState = readOperand(gift, GIFT_GAME_STATE, "the game state")
  local sellPrice = readCallTarget(gift, GIFT_SELL_PRICE, "getSellPrice")
  G.goodsReceived = readOperand(gift, GIFT_RECEIVED, "the goods statistics")
  G.goodsSent = readOperand(gift, GIFT_SENT, "the goods statistics")
  local enough = scan(AOB_ENOUGH, "the AI's trade minimum test")

  local send = scan(AOB_SEND, "how an AI answers a call for help")
  if readOperand(send, SEND_STATE, "the help request") ~= G.players + P.REQUEST_STATE
      or readOperand(send, SEND_ASKER, "the help request") ~= G.players + P.ASKER then
    error(MODULE_NAME .. ": the player array is not laid out as the module expects")
  end
  local sendTroops = readCallTarget(send, SEND_TROOPS, "sendUnitsToPlayerIDsKeepIfPossible")
  F.send = core.exposeCode(sendTroops, 3, 1)
  if readOperand(sendTroops, CAMP_X, "the helper's camp") ~= G.players + P.CAMP_X
      or readOperand(sendTroops, CAMP_Y, "the helper's camp") ~= G.players + P.CAMP_Y then
    error(MODULE_NAME .. ": the player array is not laid out as the module expects")
  end

  local gate = scan(AOB_GATE, "the gate open / close logic") + GATE_SITE
  G.gateSite = gate
  G.gateTimer = readOperand(gate, GATE_TIMER, "the gate timer")
  G.buildingArray = G.gateTimer - B.TIMER
  if G.buildingArray ~= G.buildings + B.ARRAY
      or readOperand(gate, GATE_LINK, "the gate state") ~= G.buildingArray + B.LINK
      or readOperand(gate, GATE_STATE, "the gate state") ~= G.buildingArray + B.STATE then
    error(MODULE_NAME .. ": the building array is not laid out as the module expects")
  end
  expectBytes(gate + GATE_DONE[1], GATE_DONE[2], "the end of the gate logic")
  G.gateEnd = gate + GATE_DONE[1] + 6 + rd32(gate + GATE_DONE[1] + 2)
  local apply = readCallTarget(gate, GATE_APPLY, "applyGateOrDrawbridgeOpenCloseChange")

  local k2k = scan(AOB_KEEP_TO_KEEP, "the keep to keep test")
  G.area = readOperand(k2k, K2K_AREA, "the area map")
  local tileMap = rd32(scan(AOB_TILE_FLAGS, "the tile flags") + TILE_FLAGS_OPERAND) - MAP.FLAGS
  G.rows = tileMap + MAP.ROWS
  G.yOfTile = tileMap + MAP.Y_OF_TILE
  if G.area ~= tileMap + MAP.AREA then
    error(MODULE_NAME .. ": the map layers are not laid out as the module expects")
  end

  G.teams = rd32(scan(AOB_TEAMS, "the team table") + TEAMS_OPERAND)
  G.ticks = rd32(scan(AOB_TICKS, "the game tick counter") + TICKS_OPERAND)
  local date = scan(AOB_DATE, "the game date")
  G.year, G.month = rd32(date + DATE_YEAR), rd32(date + DATE_MONTH)

  F.enough = core.exposeCode(enough, 4, 1)
  F.gain = core.exposeCode(gain, 4, 1)
  F.loss = core.exposeCode(loss, 5, 1)
  F.sellPrice = core.exposeCode(sellPrice, 4, 1)
  F.buyPrice = core.exposeCode(readCallTarget(scan(AOB_BUY, "the AI's purchase"), BUY_PRICE, "getBuyPrice"), 4, 1)
  F.requestGoods = core.exposeCode(scan(AOB_REQUEST_GOODS, "requestGoods"), 4, 1)
  if readOperand(scan(AOB_ACQUIRE, "the AI's wish list"), ACQUIRE_LIST, "the AI's wish list")
      ~= G.players + P.TO_ACQUIRE then
    error(MODULE_NAME .. ": the player array is not laid out as the module expects")
  end
  F.removeFromTribe = core.exposeCode(remove, 3, 1)
  F.addToItsTribe = core.exposeCode(its, 3, 1)
  F.addToTribe = core.exposeCode(readCallTarget(its, ITS_ADD_TO_TRIBE, "addUnitToTribe"), 3, 1)
  F.createTribe = core.exposeCode(scan(AOB_CREATE_TRIBE, "createTribeForPlayer"), 2, 1)
  F.move = core.exposeCode(scan(AOB_MOVE, "giveTribeMoveInstruction"), 7, 1)
  F.apply = core.exposeCode(apply, 4, 1)
end

local function enable(self, config)
  config = config or {}
  O.goods = setting(config, "goods", "enabled") == true
  O.goodsWeak = setting(config, "goods", "weak") == true
  O.gold = setting(config, "gold", "enabled") == true
  O.goldFactor = number(setting(config, "gold", "factor"), 1, 10000)
  O.goldShare = number(setting(config, "gold", "share"), 0, 100)
  O.goldAsk = setting(config, "gold", "ask") == true
  if O.goldShare == 0 then O.gold = false end
  O.help = setting(config, "help", "enabled") == true
  O.stayMonths = number(setting(config, "help", "months"), 0, 120)
  O.recall = setting(config, "help", "recall") == "army" and "army" or "strong"
  O.army = setting(config, "army", "enabled") == true
  O.armyShare = number(setting(config, "army", "share"), 0, 100)
  if O.armyShare == 0 then O.army = false end
  O.gates = setting(config, "gates", "enabled") == true
  O.log = setting(config, "diagnostics", "log") == true
  if not (O.goods or O.gold or O.goldAsk or O.help or O.army or O.gates) then
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
  self.saved = { { address = G.site, bytes = core.readBytes(G.site, 5) } }
  core.writeCode(G.site, { 0xE8, core.itob(core.getRelativeAddress(G.site, stub, -5)) })

  if O.gates then
    G.gateFlags = core.allocate(B.MAX, true)
    local current = core.allocate(8, true)
    local gatePad = core.allocateCode({ 0x90, 0x90, 0x90, 0x90, 0x90, 0xC3 })
    core.detourCode(function(registers)
      local hold = 0
      if not broken then
        local done, result = pcall(function()
          checkLoad()
          return gateCheck(rd32(current))
        end)
        if done then
          hold = result
        else
          broken = true
          log(WARNING, MODULE_NAME .. ": stopped after an error: " .. tostring(result))
        end
      end
      wr32(current + 4, hold)
      return registers
    end, gatePad, 5)
    local gateStub = core.allocateAssembly(GATE_STUB, {
      MAX_BUILDINGS = B.MAX, FLAGS = G.gateFlags, CURRENT = current, HOLD = current + 4, PAD = gatePad,
      TIMER = G.gateTimer, RESUME = G.gateSite + GATE_SITE_SIZE, GATE_END = G.gateEnd,
    })
    table.insert(self.saved, { address = G.gateSite, bytes = core.readBytes(G.gateSite, GATE_SITE_SIZE) })
    core.writeCode(G.gateSite, { 0xE9, core.itob(core.getRelativeAddress(G.gateSite, gateStub, -5)), 0x90, 0x90 })
  end
  log(INFO, string.format("%s: on (goods %s, gold %s, help %s, army %s%%, gates %s); hooked 0x%X",
    MODULE_NAME, O.goods and "on" or "off", O.gold and "on" or "off", O.help and "on" or "off",
    O.army and O.armyShare or 100, O.gates and "on" or "off", G.site))
end

local function disable(self, config)
  if self.saved ~= nil then
    for _, saved in ipairs(self.saved) do core.writeCode(saved.address, saved.bytes) end
    self.saved = nil
  end
end

return {
  enable = enable,
  disable = disable,
}
