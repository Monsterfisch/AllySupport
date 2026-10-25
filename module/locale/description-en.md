# Ally Support

**Author**: Monsterfish
**Version**: 1.0.7

AI allies help each other the way they already help you. Every part can be switched off in the
settings.

## Goods

When an AI lord runs short of something it can't buy, it asks its allies. Normally only you
ever answer. Now its AI allies answer too - but only if they still keep their own minimum
afterwards (the "minimum goods kept after trade" from their AI character), the same rule they
use when you ask them. Once one ally has sent the goods, the others don't. An ally that can't
spare it turns the request down at once, so the asker can ask again (for something else, or
for gold).

AI lords only ask when they need something they can't afford to buy, so it doesn't happen
all the time. What they send shows in the goods sent / received statistics at the end.

If the asking ally is in a weak state and the giver can't spare the full amount, it still
sends up to half of what was asked for, going down to half of its own minimum if it must.

## Gold

A rich AI ally that is asked for goods also sends gold. Rich means it has at least 100 times
its trade minimum in gold. It sends a quarter of what it has above that line, and only to an
ally poorer than itself.

## Asking for gold

When an AI lord wants goods it can't afford, it now asks its allies - you and the AIs - for the
gold it is short, at most once a month. You see it on your ally screen like any other request.
An AI ally sends the gold if it still keeps its "rich" line afterwards; to a weak ally it sends
up to half, going down to half that line if it must.

## Troops

- **AI allies help each other.** When enemies close in on an AI lord, its AI allies send their
  troops, just as they do when you ask for help. An ally only comes if it isn't under threat
  itself, isn't busy attacking, and has the army size its AI character needs before helping.
  Its attack army stays at least 6 in-game months, and longer while the castle is still in
  danger. It goes home at once if the ally feels strong again - or, if you pick that in the
  settings, as soon as the helping lord's own army is big enough to attack, so the stay doesn't
  hold back its attack. The troops then march back to their own castle, and that lord waits 3
  months (or until its own attack) before it helps again.
- **75% of the attack army goes.** Whenever an AI ally helps - you or another AI - it sends
  75% of its attack army and keeps the rest at its own camp. Castle defenders, patrols and
  raiders always stay. Engineers, laddermen, tunnellers and siege engines are the first to stay
  home. When the help ends, everyone rejoins the army.
- **The gate opens for the helpers.** When the helping troops stand in front of a gate of the
  castle they help, the gate opens and they go inside to the lord's camp. Once nobody is waiting
  at the door, the gate closes again by itself as usual (if enemies are near). When the help
  ends, the gate opens the same way to let them out. This works for your gates too.

Only allies (same team) get goods, gold or troops.

## Good to know

- Requests from you and to you work exactly as before.
- Not yet tested in game.
