# Issues & Improvements

Tracked backlog from codebase audit. For higher-level roadmap items (Cooking trainer data, specializations, live AH scan, merchant recording, travel planning), see [TODO.md](TODO.md).

Pick one item at a time on a fresh branch, add a failing test to `Tools/dev/test.lua` first where applicable, fix it, and check it off here.

---

## Foundations & Data Model

- [x] **#1 Unique recipe keys & spell IDs for item-producing recipes** (`Tools/build_recipes.py`, `Data/Recipes.lua`, `Core.lua`, `Scan.lua`, `UI.lua`)
  - `ns.RecipeKey(rec)` keys item recipes only by output item ID (`"i:" .. rec.i`), which collides when multiple recipes produce the same item (e.g. Alchemy *Essence of Earth* ×2, *Essence of Water* ×2). Duplicate names (*Faction Banner* ×2 in Tailoring) also collide in `Scan.Index().byName`.
  - Include spell ID (`sp`) from DB2 data where available (or disambiguate duplicate keys) so `known`, `planned`, `trainer`, `yields`, and `freeze`/`thaw` never collide.
  - **Done when:** Every recipe in `Data/Recipes.lua` has a unique `ns.RecipeKey(rec)` and round-trips cleanly through `Scan` and `freeze`/`thaw`.

- [ ] **#2 Bake craft yields into static recipe data** (`Tools/build_recipes.py`, `Data/Recipes.lua`, `Scan.lua`, `Planner.lua`)
  - Multi-yield recipes (dynamite/bombs making 2–3, ammo making 100–200, multi-yield cooking/potions/intermediates) default to `yield = 1` until the player opens that profession window, distorting intermediate costs, sale credits, and prep craft quantities.
  - Also `Scan.TradeSkill` uses `quantityMin` instead of the expected average `(quantityMin + quantityMax) / 2` for variable-yield crafts.
  - Extract craft yields from `SpellEffect.csv` in `build_recipes.py` and fall back to scanned yields only as an override.
  - **Done when:** Multi-yield recipes have accurate yields in `Data/Recipes.lua` even on a fresh profile with no tradeskill scan.

- [ ] **#3 Guard `savedPlan` / `thaw` against missing recipe keys** (`UI.lua`)
  - If a future `Data/Recipes.lua` update removes or renames a recipe key saved in `jewilUI_ProfessionLevelerCharDB.plans`, `thaw` replaces `{ __rec = key }` with `nil` and `UI.Render` crashes on `st.rec.n`.
  - Detect any unresolved `__rec` during `thaw` and discard the stale saved plan so `UI.Refresh` automatically replans.
  - **Done when:** Unit test with an unknown `__rec` key in a frozen plan cleanly triggers a fresh replan instead of crashing.

---

## Bugs

- [ ] **#4 Shared-reagent `INF` crash & silently dropped materials** (`Planner.lua`)
  - Dry-run calls (`commit = false`) in `Ctx:PointCost` and `Ctx:ReagentCost` don't tentatively track usage across multiple reagents in the same craft (or nested prep crafts). When two reagents share a limited-supply base material, dry run succeeds while `commit = true` hits `INF` — crashing in `record` (`crafts == nil`) or silently dropping reagents from the shopping list in recursive prep commits.
  - Track tentative usage within a single dry-run craft evaluation (or roll back on commit failure) and guard `PointCost`/`ReagentCost` commit return values.
  - **Done when:** Unit test where a recipe and its prep-crafted intermediate share a scarce base material never crashes and accounts for 100% of materials.

- [ ] **#5 Required tool recipes omitted from Shopping List when `startSkill >= rec.k[4]`** (`Planner.lua`)
  - `acquire` only iterates `candidates` (which excludes recipes grey at `startSkill`). A character starting above a required tool's grey level still gets the tool scheduled by `doTool`, and `UI.lua` points to *"in Recipes above"*, but the pattern is never added to `acquire` or `totals.recipes`.
  - Also `ctx.allowed[rec] = true` is set even when `ctx.acq[rec]` is `nil` (`unpriced`), making an unobtainable tool recipe eligible for regular leveling steps.
  - **Done when:** Unit test for an unowned required tool past its grey skill includes its recipe in `acquire`/`totals.recipes` and never uses unpriced tool recipes for non-tool leveling steps.

- [ ] **#6 Learned optional recipes stay stuck in Step 2 with a red error** (`UI.lua`, `Scan.lua`)
  - Once you learn a recipe you ticked in Step 2 (`cdb.planned[prof][key] = true`), `Planner.Acquisition` returns `"known"` before `"planned"`, so Step 2 still displays the ticked recipe with a red **`- not used by the plan`** warning.
  - Clear `cdb.planned[prof][key]` when `Scan.TradeSkill` sees it as known (and filter `known[key]` out of Step 2 in `UI.Render`).
  - **Done when:** Unit test shows a previously planned recipe disappears from Step 2 once marked known.

- [ ] **#7 Trainer fees included in `Recipes:` total but hidden from the Recipes table** (`UI.lua`)
  - `totals.recipes` sums trainer fees recorded by `Scan.Trainer()`, while Step 3's `Recipes` table only shows `how == "AH" or how == "vendor"`, making the statement summary disagree with the itemized table.
  - Either display trainer fees in the breakdown (e.g. a separate `Trainer fees:` line or an itemized row) or clearly label the split.
  - **Done when:** Sum of itemized recipe/trainer costs matches the Step 3 statement summary.

- [ ] **#8 Clicking `Re-plan` wipes a custom `Start skill`** (`UI.lua`)
  - Pressing Enter on `Start skill` builds a plan with `plan.start == typed`, so a subsequent click on **Re-plan** sees `typed == plan.start` and resets `state.start = nil`, reverting to your character's current skill.
  - Track explicitly whether the user typed a custom start skill (clear only when blanking the box or switching tabs).
  - **Done when:** Custom start skill persists across `Re-plan` clicks until cleared.

- [ ] **#9 Live trainer scan lacks name aliases** (`Scan.lua`, `Tools/build_trainers.py`, `Data/TrainerData.lua`)
  - Trainer windows display spell names (e.g. *Enchanted Thorium*) while `Data/Recipes.lua` stores output item names (*Enchanted Thorium Bar*). `build_trainers.py` supports `alias:`, but `Scan.Trainer()` matches `byName` directly and silently skips aliased recipes.
  - Emit the alias map into `Data/TrainerData.lua` and consult it in `Scan.Trainer()`.
  - **Done when:** `Scan.Trainer()` matches aliased trainer names cleanly in unit tests.

- [ ] **#10 Rank cap banners ignore character's current `maxRank`** (`UI.lua`)
  - `RANK_CAPS = { 75, 150, 225 }` prompts *"Train the next rank before 150"* even if the character already trained Expert (`maxRank == 225`) at skill 125.
  - Check `select(2, ns.CharSkill(plan.prof))` (stored on the plan) and skip rank banners already below/at `maxRank`.
  - **Done when:** Planning `125 -> 225` with `maxRank == 225` omits the 150 banner.

---

## Small Polish Batch

Can be bundled into a single quick cleanup branch:

- [ ] **#11 Toggling `Avoid green` in UI should call `UI.SettingsChanged()`** (`UI.lua`) so other professions' saved plans are marked stale.
- [ ] **#12 `Scan.Trainer()` marks all professions stale** (`Scan.lua`) instead of only the profession(s) actually updated during that trainer visit.
- [ ] **#13 Validate slash command arguments** (`Core.lua`) — `/cp ahsell <typo>` shouldn't silently remove items; `/cp opt <name> <val>` should require `on` or `off`.
- [ ] **#14 Hover tooltip `"Shift-click to search the AH"` shown on soulbound tools & vendor-only items** (`UI.lua`) — omit the AH search hint when the item isn't buyable on the AH.
- [ ] **#15 Dead ternary `nextGrid and 1 or 1`** (`UI.lua:712`) — verify intended bottom border inset on table row hover highlight.
- [ ] **#16 Optional `jewilUI` dependency** (`jewilUI_ProfessionLeveler.toc`) — `jewilUI` is only used for `IconTexture`; consider `OptionalDeps: jewilUI` so the addon can also run standalone.

---

## Algorithmic & Economic Improvements

- [ ] **#17 Tiered AH pricing (order-book depth)** (`Core.lua`, `Scan.lua`, `Prices.lua`, `Planner.lua`, `UI.lua`)
  - Currently `Prices.AH` only reads Auctionator's single lowest buyout and assumes the entire listed supply (`ahQty`) is available at that minimum price. A single cheap "bait" auction makes an expensive reagent look dirt cheap.
  - Capture per-price-tier order-book depth during Auctionator full scans (and live searches) and walk price tiers sequentially in `Planner.lua` for exact-quantity costing, hybrid AH+vendor / AH+prep-craft splits, and price-range display in `UI.lua`.
  - **Done when:** Unit tests verify tiered AH costing, bait-auction immunity in Pass 1, hybrid AH+vendor/prep splits, and graceful fallback when only flat Auctionator prices exist.

- [ ] **#18 Guard against limited-stock / faction-locked vendor prices** (`Prices.lua`, `Planner.lua`)
  - Auctionator's `GetVendorPriceByItemID` caches limited-stock and opposing-faction vendor items, which `Planner.lua` treats as infinite supply.
  - Whitelist known unlimited vendor reagents (or capture vendor stock limits via `MERCHANT_SHOW` when implementing merchant scanning from `TODO.md`).

- [ ] **#19 Required tool superseding / hierarchy** (`Data/RequiredTools.lua`, `Planner.lua`)
  - Owning a higher-tier Enchanting rod (e.g. `Runed Truesilver Rod`) satisfies all lower-tier rods; don't force crafting Copper/Silver/Golden rods if a higher rod is owned.

- [ ] **#20 Prep-craft folding, skill progression & Step 3 vs Step 4 rounding alignment** (`Planner.lua`, `UI.lua`)
  - Folding later prep crafts back into an earlier leveling step changes when those crafts happen (potentially giving skill-ups early instead of being grey later) and assumes the same recipe.
  - Prep skill-ups advancing `x` don't re-evaluate `pick` at `math.floor(x)`; fractional tool skill-ups can silently carry over to later steps; Step 3 rounds per-item totals while Step 4 rounds per-row crafts.

- [ ] **#21 Clarify or harden `"Avoid green"` behavior** (`Core.lua`, `Planner.lua`, `UI.lua`)
  - Currently `avoidGreen` only zeros out sale/reuse credit on green crafts, so cheap-material green crafts are still chosen despite high RNG variance. Decide whether to truly penalize/avoid green crafts unless no orange/yellow option exists, or clarify the tooltip/label.

- [ ] **#22 Cheapest `Ctx:Maker` & deeper craft chains (`MAX_DEPTH > 2`)** (`Planner.lua`)
  - `Ctx:Maker` picks the lowest learn-level recipe instead of the cheapest one when multiple recipes produce the same item, and `MAX_DEPTH = 2` cuts off 3-step Engineering component chains.

- [ ] **#23 Pass 1 bag awareness & Pass 2 pattern profitability verification** (`Planner.lua`)
  - Pass 1 ignores reagents already in bags/bank (so it won't buy a cheap pattern that burns free bank mats) and never considers buying a grey recipe for cheap prep crafts.

- [ ] **#24 AH deposit fees & BoP check on `ahSell`** (`Prices.lua`, `Core.lua`)
  - Prevent BoP items from being added to `ahSell` and optionally factor AH deposit/relist overhead into AH resale valuation.

---

## Missing Features & UX

- [ ] **#25 Auctionator Shopping List export** (`UI.lua`)
  - One-click button in Step 3 to push all AH materials into an Auctionator shopping list (`Auctionator.API.v1.CreateShoppingList` / search list).

- [ ] **#26 Live shopping progress tracking** (`UI.lua`)
  - Show *"Have X / Need Y"* (or checkmarks) on Step 3 rows against current bags/bank as you buy, without forcing a Re-plan.

- [ ] **#27 Step 2 (Optional Recipes) UX polish** (`UI.lua`)
  - Add hover tooltips (pattern/product info + reagents), Shift-click AH search, and make clicking the entire row toggle the checkbox.

- [ ] **#28 Expose hidden planner settings in UI** (`UI.lua`)
  - Add UI controls (e.g. a small settings popover) for `useBags`, `includeBooks`, `includeRep`, `maxAgeDays`, `thinRatio`, and `ahSell` management.

- [ ] **#29 Actual faction reputation checking & character level warnings** (`Core.lua`, `Planner.lua`, `UI.lua`)
  - Check `GetFactionInfo` against the 174 `rep`-tagged recipes instead of an all-or-nothing `includeRep` toggle; warn on rank banners if character level is below the rank requirement.

- [ ] **#30 Support First Aid & Mining (Smelting)** (`Tools/build_recipes.py`, `Core.lua`, `Data/`)
  - Both can be leveled largely or completely from AH materials.

- [ ] **#31 Racial profession bonuses & skill caps > 300** (`Core.lua`, `Planner.lua`)
  - Handle Gnome +15 Engineering (315 cap) and `skillModifier` from `GetProfessionInfo`.

- [ ] **#32 Faction filtering & crafting-station warnings** (`Data/`, `Planner.lua`, `UI.lua`)
  - Filter Alliance/Horde-only recipes via `UnitFactionGroup`; warn when a recipe requires a Black Forge/Anvil (BRD), Alchemy Lab, Moonwell, or Cooking Fire.

- [ ] **#33 RNG safety margin / budget buffer option** (`Planner.lua`, `UI.lua`)
  - Optional buffer (e.g. +15% or 90th-percentile crafts for yellow/green steps) so unlucky streaks don't send the player back to the AH mid-session.

- [ ] **#34 Enchanting target gear reminders & entry-point button** (`UI.lua`)
  - Remind Enchanters which cheap gear slot (Bracer/Chest/Cloak/etc. + min ilvl) to carry for repeatable enchants; add a TradeSkill-frame or minimap button so `/cp` isn't the only way to open the window.

- [ ] **#35 Classic TradeSkill/Craft API fallback** (`Scan.lua`)
  - Verify whether Enchanting / older Classic APIs need a `GetNumTradeSkills`/`GetNumCrafts` fallback in `Scan.TradeSkill`.
