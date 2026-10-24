# Ally Support

A UCP3 module for Stronghold Crusader and Stronghold Crusader Extreme. AI allies help each other
the way they already help the player: they answer each other's requests for goods (by their AIC
trade minimum), rich lords send gold, they come to each other's aid, and an AI that helps anyone
sends at least 75% of its army.

What the module does, in plain English, is in `module/locale/description-en.md`; how it does it
is in the comment at the top of `module/init.lua`.

## Working on it

1. Edit under `module/`.
2. `python tools/publish.py --bump` - raises the last version slot and copies the module to
   `ucp/modules/ally-support-<version>`. Do this with the game closed.
3. In the UCP GUI press F5, then apply.
4. Commit and tag: `git commit -am "<version> - <what changed>" && git tag v<version>`.
