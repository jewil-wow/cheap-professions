-- Approximate vendor BUY prices (copper per unit) for common vendor-sold reagents.
-- Only a fallback: Auctionator records the real price (incl. reputation discount)
-- whenever you open a merchant that sells the item, and that always wins.
-- Values are from classic-era memory and may be off; the plan marks them with "~".
local _, ns = ...

ns.Data.vendorSeed = {
    [2320] = 10,    -- Coarse Thread
    [2321] = 100,   -- Fine Thread
    [4291] = 500,   -- Silken Thread
    [8343] = 2000,  -- Heavy Silken Thread
    [14341] = 5000, -- Rune Thread
    [2324] = 25,    -- Bleach
    [2604] = 50,    -- Red Dye
    [6260] = 50,    -- Blue Dye
    [2605] = 100,   -- Green Dye
    [4340] = 350,   -- Gray Dye
    [4341] = 500,   -- Yellow Dye
    [4342] = 2500,  -- Purple Dye
    [2325] = 1000,  -- Black Dye
    [6261] = 1000,  -- Orange Dye
    [10290] = 2500, -- Pink Dye
    [4289] = 50,    -- Salt
    [2678] = 10,    -- Mild Spices
    [2692] = 40,    -- Hot Spices
    [3713] = 160,   -- Soothing Spices
    [4399] = 200,   -- Wooden Stock
    [4400] = 2000,  -- Heavy Stock
    [6217] = 124,   -- Copper Rod
    [3371] = 4,     -- Empty Vial
    [3372] = 40,    -- Leaded Vial
    [8925] = 500,   -- Crystal Vial
    [2880] = 100,   -- Weak Flux
    [3466] = 2000,  -- Strong Flux
    [159] = 5,      -- Refreshing Spring Water
    [1179] = 25,    -- Ice Cold Milk
    [4470] = 38,    -- Simple Wood
    [3857] = 500,   -- Coal
}
