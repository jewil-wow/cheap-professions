-- Tools a profession has to carry that levelling guides leave out. The planner schedules a
-- craft of each one (unless it's already in your bags or bank), whether or not it's the
-- cheapest skill-up at that point.
--   item = the tool's item id (its recipe is looked up in Data/Recipes.lua)
--   at   = skill to craft it at (or as soon as the recipe can be learned after that)
--   maxAt = optional upper skill bound; when set, craft at the costliest point in [at, maxAt]
--   by   = skill you need it by (only used for buyable tools; defaults to `at`)
--   boe  = it can be bought, so the planner compares buying it to crafting it
--   minTarget = only include it when the plan goes at least this high
local _, ns = ...

ns.Data.requiredTools = {
    alchemy = {
        { item = 9149, at = 225, maxAt = 239, minTarget = 275 }, -- Philosopher's Stone (orange 225-239, needed for transmutes at 275)
    },
    enchanting = {
        { item = 6218, at = 1 },                    -- Runed Copper Rod
        { item = 6339, at = 109 },                  -- Runed Silver Rod
        { item = 11130, at = 150 },                 -- Runed Golden Rod
        { item = 11145, at = 200 },                 -- Runed Truesilver Rod
        { item = 16207, at = 290, minTarget = 300 }, -- Runed Arcanite Rod (formula isn't taught by trainers)
    },
    engineering = {
        { item = 6219, at = 50, by = 60, boe = true }, -- Arclight Spanner
    },
}
