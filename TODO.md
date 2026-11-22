# Cheap Professions TODO

## Trainer data for the other professions
Leatherworking is done (`Tools/trainer_raw/leatherworking.txt`). Still needed:

- [ ] Alchemy
- [ ] Blacksmithing
- [ ] Enchanting
- [ ] Engineering
- [ ] Tailoring
- [ ] Cooking

For each: open the profession's trainer (one that teaches up to the last rank), copy the
two lists (services, then the skill each one needs) into
`Tools/trainer_raw/<profession>.txt` in the same format as the leatherworking file, then run

    python3 -I Tools/build_trainers.py Tools/trainer_raw Data/TrainerData.lua

Add a `complete` line only if the list is the profession's full trainer offering.
Until a profession has trainer data, its trainer recipes use estimated learn levels (marked `~`).

Open question: the leatherworking list ends with a rank whose requirement showed as `??`.

## Specializations
Forever still has profession specializations (e.g. leatherworking Dragonscale / Elemental /
Tribal; blacksmithing Armorsmith / Weaponsmith; engineering Gnomish / Goblin). Right now the
planner treats every recipe on the trainer list as learnable, including specialization ones.

- [ ] Find out which trainer recipes need which specialization (the trainer window shows
  "Requires Dragonscale Leatherworking" etc.; Wowhead recipe pages too). For leatherworking
  the ones to check are: Wolfshead Helm, Gauntlets of the Sea, Dragonscale Gauntlets,
  Helm of Fire, Feathered Breastplate, Dragonscale Breastplate, Green Dragonscale Gauntlets,
  Blue Dragonscale Leggings. Don't assume classic's mapping.
- [ ] Add a per-profession "Specialization" setting (none / one of the specs). Only the
  chosen spec's recipes count as trainer-learnable; others show under Optional Recipes,
  marked with the spec they need.
- [ ] Have the trainer scan record "Requires <specialization>" (GetTrainerServiceAbilityReq)
  so this data fills in automatically when someone visits a trainer.

## Crafts worth selling on the AH
- [ ] Work out the full list of crafted items worth selling on the AH instead of vendoring
  (today only Hillman's Cloak is on it; add more with `/cp ahsell add <item>`).
  Ideas: compare AH price (minus cut) to vendor price for every craft in the levelling
  plans, require enough recent listings/sales that it actually sells, and seed the
  defaults in `Core.lua` (`ahSell` seed list).

## Later
- [ ] Live AH scan of just the plan's materials (real price-by-quantity), re-plan from it, buy scarce items first.
- [ ] Record merchants you visit (items, prices incl. limited-stock patterns, vendor, zone) and ship that data like the trainer data.
- [ ] Ask MetaForge for permission to use their vendor/drop data (their terms forbid automated collection otherwise).
- [ ] Travel planning: group trainer/vendor stops by zone so you buy everything in one trip.
- [ ] Cap how many AH-sold crafts (e.g. Hillman's Cloak) the plan expects to sell, based on how many are listed.
