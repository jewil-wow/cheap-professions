-- Baseline test suite for jewilUI_ProfessionLeveler.
--
-- Usage:
--   lua5.1 Tools/dev/test.lua              -- run all tests
--   lua5.1 Tools/dev/test.lua planner      -- run tests whose name matches "planner"
--
-- Add 1-2 regression tests here whenever tackling an item from ISSUES.md.
local root = (debug.getinfo(1, "S").source:sub(2):match("^(.*)/Tools/dev/") or ".") .. "/"
local filter = arg[1] and arg[1]:lower()

-- Minimal test harness -----------------------------------------------------
local passed, failed, skipped = 0, 0, 0
local failures = {}

local function eq(got, want, msg)
    if got ~= want then
        error(("%s: expected %s, got %s"):format(msg or "eq", tostring(want), tostring(got)), 2)
    end
end

local function near(got, want, tol, msg)
    if type(got) ~= "number" or math.abs(got - want) > (tol or 1e-4) then
        error(("%s: expected ~%s, got %s"):format(msg or "near", tostring(want), tostring(got)), 2)
    end
end

local function ok(cond, msg)
    if not cond then error(msg or "assertion failed", 2) end
end

local function stripColor(s)
    return (tostring(s):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""))
end

-- WoW & Auctionator stubs --------------------------------------------------
local noop = function() end
local function stubObject()
    local scripts = {}
    return setmetatable({ scripts = scripts }, {
        __index = function(_, k)
            if k == "SetScript" then return function(_, name, fn) scripts[name] = fn end end
            if k == "GetScript" then return function(_, name) return scripts[name] end end
            return noop
        end,
    })
end

local frames = {}
function CreateFrame() local f = stubObject() frames[#frames + 1] = f return f end
C_Timer = { After = function(_, fn) fn() end }
function CopyTable(t) local r = {} for k, v in pairs(t) do r[k] = type(v) == "table" and CopyTable(v) or v end return r end
function strtrim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end
function geterrorhandler() return function(e) error("ADDON ERROR: " .. tostring(e)) end end
function debugprofilestop() return os.clock() * 1000 end
function tinsert(t, v) table.insert(t, v) end
date = os.date
UISpecialFrames, SlashCmdList, UIParent = {}, {}, {}

-- Mutable mock state reset before each test
local fakeNow = 1700000000
local mockBags = {}
local mockSellPrice = {}
local mockItemName = {}
local mockAucPrice, mockAucAge, mockAucQty, mockVendor = {}, {}, {}, {}
local mockTrainerServices = {}
local mockTradeSkill = { prof = nil, linked = false, recipes = {} }
local mockCharProfs = {}
local prints = {}

function time() return fakeNow end

-- Silence addon chat prints during tests (still captured in `prints`)
local realPrint = print
print = function(...)
    local t = {}
    for i = 1, select("#", ...) do t[i] = tostring(select(i, ...)) end
    prints[#prints + 1] = table.concat(t, "\t")
end

C_Item = {
    GetItemInfo = function(id)
        local n, sell = mockItemName[id], mockSellPrice[id]
        if n == nil and sell == nil then return nil end
        return n or ("item:" .. id), nil, nil, nil, nil, nil, nil, nil, nil, nil, sell or 0
    end,
    GetItemCount = function(id) return mockBags[id] or 0 end,
    RequestLoadItemDataByID = noop,
}

C_TradeSkillUI = {
    IsTradeSkillLinked = function() return mockTradeSkill.linked end,
    IsNPCCrafting = function() return false end,
    IsTradeSkillGuild = function() return false end,
    GetBaseProfessionInfo = function()
        if not mockTradeSkill.prof then return nil end
        return { professionName = mockTradeSkill.prof }
    end,
    GetAllRecipeIDs = function()
        local ids = {}
        for id in pairs(mockTradeSkill.recipes) do ids[#ids + 1] = id end
        return ids
    end,
    GetRecipeInfo = function(id)
        local r = mockTradeSkill.recipes[id]
        return r and { name = r.name, learned = r.learned } or nil
    end,
    GetRecipeSchematic = function(id)
        local r = mockTradeSkill.recipes[id]
        if not r then return nil end
        local qMin = r.yieldMin or r.yield or 1
        local qMax = r.yieldMax or r.yield or qMin
        return { outputItemID = r.item, quantityMin = qMin, quantityMax = qMax }
    end,
}

function GetProfessions()
    if #mockCharProfs == 0 then return end
    local idxs = {}
    for i = 1, #mockCharProfs do idxs[i] = i end
    return unpack(idxs)
end
function GetProfessionInfo(idx)
    local p = mockCharProfs[idx]
    if not p then return end
    return p.name, nil, p.rank, p.maxRank, nil, nil, p.line
end

function GetNumTrainerServices() return #mockTrainerServices end
function GetTrainerServiceInfo(i) local s = mockTrainerServices[i] return s and s.name end
function GetTrainerServiceSkillReq(i) local s = mockTrainerServices[i] return s and s.skill, s and s.rank end
function GetTrainerServiceCost(i) local s = mockTrainerServices[i] return s and s.cost end
function GetTrainerServiceItemLink(i) local s = mockTrainerServices[i] return s and s.link end

Auctionator = {
    SavedState = {},
    API = { v1 = {
        GetAuctionPriceByItemID = function(_, id) return mockAucPrice[id] end,
        GetAuctionAgeByItemID = function(_, id) return mockAucAge[id] or 0 end,
        GetVendorPriceByItemID = function(_, id) return mockVendor[id] end,
    } },
    Database = {
        GetPriceHistory = function(_, key)
            local q = mockAucQty[tonumber(key)]
            return q and { { available = q } } or {}
        end,
    },
}

-- Load addon files once ----------------------------------------------------
local ns = {}
local ADDON_FILES = {
    "Core.lua", "Data/Recipes.lua", "Data/TrainerData.lua",
    "Data/VendorSeed.lua", "Data/RequiredTools.lua",
    "Prices.lua", "Scan.lua", "Planner.lua", "Skin.lua", "UI.lua",
}
for _, file in ipairs(ADDON_FILES) do
    local chunk = assert(loadfile(root .. file))
    chunk("jewilUI_ProfessionLeveler", ns)
end
local onEvent = frames[1].scripts.OnEvent
onEvent(frames[1], "ADDON_LOADED", "jewilUI_ProfessionLeveler")

-- Helpers ------------------------------------------------------------------
local function resetEnv()
    fakeNow = 1700000000
    mockBags, mockSellPrice, mockItemName = {}, {}, {}
    mockAucPrice, mockAucAge, mockAucQty, mockVendor = {}, {}, {}, {}
    mockTrainerServices = {}
    mockTradeSkill = { prof = nil, linked = false, recipes = {} }
    mockCharProfs = {}
    prints = {}
    Auctionator.SavedState = {}
    jewilUI_ProfessionLevelerDB = nil
    jewilUI_ProfessionLevelerCharDB = nil
    onEvent(frames[1], "ADDON_LOADED", "jewilUI_ProfessionLeveler")
end

local function test(name, fn)
    if filter and not name:lower():find(filter, 1, true) then
        skipped = skipped + 1
        return
    end
    resetEnv()
    local success, err = pcall(fn)
    if success then
        passed = passed + 1
        realPrint("  PASS  " .. name)
    else
        failed = failed + 1
        failures[#failures + 1] = { name = name, err = err }
        realPrint("  FAIL  " .. name .. "\n        " .. tostring(err))
    end
end

local function allKnownItems()
    local items, books = {}, {}
    for _, list in pairs(ns.Data.recipes) do
        for _, rec in ipairs(list) do
            if rec.i then items[rec.i] = true end
            if rec.book then items[rec.book] = true; books[rec.book] = true end
            for j = 1, #rec.rg, 2 do items[rec.rg[j]] = true end
        end
    end
    for _, defs in pairs(ns.Data.requiredTools or {}) do
        for _, def in ipairs(defs) do items[def.item] = true end
    end
    return items, books
end

local function setAH(id, price, qty, age)
    mockAucPrice[id] = price
    mockAucQty[id] = qty
    mockAucAge[id] = age or 0
end

local function findShopRow(plan, itemID)
    for _, r in ipairs(plan.shopping) do
        if r.item == itemID then return r end
    end
end

local function findRecipe(prof, name)
    for _, rec in ipairs(ns.Data.recipes[prof]) do
        if rec.n == name then return rec end
    end
end

-- =========================================================================
-- 1. Core helpers, character skill & slash commands
-- =========================================================================
test("core: ProfKey, RecipeKey, CharSkill, and default seed", function()
    eq(ns.ProfKey(197), "tailoring", "skill line id -> key")
    eq(ns.ProfKey("Leatherworking"), "leatherworking", "display name -> key")
    eq(ns.ProfKey("blacksmithing"), "blacksmithing", "slug -> key")
    eq(ns.ProfKey("nonexistent"), nil, "unknown returns nil")

    eq(ns.RecipeKey({ i = 2996 }), "i:2996", "item recipe key")
    eq(ns.RecipeKey({ sp = 7418 }), "s:7418", "spell recipe key")

    -- Default ahSell seed includes Hillman's Cloak
    local cloak = assert(findRecipe("leatherworking", "Hillman's Cloak"))
    eq(ns.db.ahSell[cloak.i], true, "Hillman's Cloak seeded in ahSell")

    -- CharSkill reads GetProfessions / GetProfessionInfo
    eq(ns.CharSkill("tailoring"), nil, "unlearned profession returns nil")
    mockCharProfs = { { name = "Tailoring", rank = 135, maxRank = 225, line = 197 } }
    local rank, maxRank = ns.CharSkill("tailoring")
    eq(rank, 135, "rank")
    eq(maxRank, 225, "maxRank")
end)

test("core: slash commands toggle options and manage ahSell", function()
    SlashCmdList.JEWILUI_PROFESSIONLEVELER("opt bags off")
    eq(ns.db.opts.useBags, false, "bags off")
    SlashCmdList.JEWILUI_PROFESSIONLEVELER("opt books off")
    eq(ns.db.opts.includeBooks, false, "books off")
    SlashCmdList.JEWILUI_PROFESSIONLEVELER("opt rep on")
    eq(ns.db.opts.includeRep, true, "rep on")
    SlashCmdList.JEWILUI_PROFESSIONLEVELER("opt green on")
    eq(ns.db.opts.avoidGreen, false, "green on => avoidGreen false")
    SlashCmdList.JEWILUI_PROFESSIONLEVELER("opt green off")
    eq(ns.db.opts.avoidGreen, true, "green off => avoidGreen true")

    SlashCmdList.JEWILUI_PROFESSIONLEVELER("ahsell add 2996")
    eq(ns.db.ahSell[2996], true, "ahsell add by id")
    SlashCmdList.JEWILUI_PROFESSIONLEVELER("ahsell remove 2996")
    eq(ns.db.ahSell[2996], nil, "ahsell remove by id")
    SlashCmdList.JEWILUI_PROFESSIONLEVELER("ahsell add Bolt of Linen Cloth")
    eq(ns.db.ahSell[2996], true, "ahsell add by item name")
end)

-- =========================================================================
-- 2. Prices
-- =========================================================================
test("prices: Money, Vendor seed vs Auctionator, Bags vs Owned, SaleValue, AH", function()
    eq(stripColor(ns.Prices.Money(45)), "45c", "copper only")
    eq(stripColor(ns.Prices.Money(205)), "2s 05c", "silver + copper")
    eq(stripColor(ns.Prices.Money(12345)), "1g 23s", "gold + silver")
    eq(stripColor(ns.Prices.Money(-10500)), "-1g 05s", "negative gold")

    -- Vendor seed fallback vs Auctionator vendor override
    local p, seed = ns.Prices.Vendor(2320) -- Coarse Thread seed = 10c
    eq(p, 10, "vendor seed price")
    eq(seed, true, "marked as seed")
    mockVendor[2320] = 9
    p, seed = ns.Prices.Vendor(2320)
    eq(p, 9, "Auctionator vendor price wins over seed")
    eq(seed, false, "not seed")

    -- Bags respect useBags; Owned ignores useBags
    mockBags[2589] = 42
    eq(ns.Prices.Bags(2589), 42, "Bags returns count when useBags=true")
    ns.db.opts.useBags = false
    eq(ns.Prices.Bags(2589), 0, "Bags returns 0 when useBags=false")
    eq(ns.Prices.Owned(2589), 42, "Owned ignores useBags")

    -- AH price, age, qty, and staleness filter
    setAH(2589, 150, 80, 1)
    local ap, age, qty = ns.Prices.AH(2589)
    eq(ap, 150, "AH price")
    eq(age, 1, "AH age")
    eq(qty, 80, "AH qty from GetPriceHistory")
    mockAucAge[2589] = ns.db.opts.maxAgeDays + 1
    eq(ns.Prices.AH(2589), nil, "stale AH price ignored")

    -- SaleValue: vendor by default, AH minus cut when on ahSell
    mockSellPrice[2996] = 100
    setAH(2996, 1000, 20, 0)
    local v, src = ns.Prices.SaleValue(2996)
    eq(v, 100, "defaults to vendor sell price")
    eq(src, "vendor", "src = vendor")
    ns.db.ahSell[2996] = true
    local info
    v, src, info = ns.Prices.SaleValue(2996)
    eq(v, 950, "ahSell applies 5% cut")
    eq(src, "ah", "src = ah")
    eq(info.ah, 1000, "sale info preserves raw AH price")
    eq(info.vendor, 100, "sale info preserves vendor price")
end)

-- =========================================================================
-- 3. Scanning (tradeskill window & trainer window)
-- =========================================================================
test("scan: TradeSkill records known recipes & multi-yields, ignores linked windows", function()
    local bolt = assert(findRecipe("tailoring", "Bolt of Linen Cloth"))
    local bag = assert(findRecipe("tailoring", "Linen Bag"))
    mockTradeSkill = {
        prof = "Tailoring",
        linked = false,
        recipes = {
            [1001] = { name = "Bolt of Linen Cloth", item = bolt.i, learned = true, yield = 1 },
            [1002] = { name = "Linen Bag", item = bag.i, learned = false, yield = 2 },
        },
    }
    ns.Scan.TradeSkill()
    eq(ns.cdb.known.tailoring[ns.RecipeKey(bolt)], true, "learned recipe recorded")
    eq(ns.cdb.known.tailoring[ns.RecipeKey(bag)], nil, "unlearned recipe not marked known")
    eq(ns.db.yields.tailoring[ns.RecipeKey(bolt)], nil, "yield 1 not stored redundantly")
    eq(ns.db.yields.tailoring[ns.RecipeKey(bag)], 2, "yield > 1 recorded")

    -- Linked tradeskill window (e.g. guildmate's chat link) must NOT overwrite known
    mockTradeSkill.linked = true
    mockTradeSkill.recipes = { [1002] = { name = "Linen Bag", item = bag.i, learned = true } }
    ns.Scan.TradeSkill()
    eq(ns.cdb.known.tailoring[ns.RecipeKey(bolt)], true, "linked window ignored")
    eq(ns.cdb.known.tailoring[ns.RecipeKey(bag)], nil, "linked window did not leak")
end)

test("scan: Trainer records exact learn levels and fees", function()
    local bag = assert(findRecipe("tailoring", "Linen Bag"))
    mockTrainerServices = {
        { name = "Linen Bag", skill = "Tailoring", rank = 45, cost = 150 },
    }
    ns.Scan.Trainer()
    local info = ns.db.trainer.tailoring and ns.db.trainer.tailoring[ns.RecipeKey(bag)]
    ok(info, "recorded in ns.db.trainer")
    eq(info.skill, 45, "learn level recorded")
    eq(info.cost, 150, "trainer cost recorded")
    local learn, exact = ns.Planner.LearnLevel("tailoring", bag)
    eq(learn, 45, "LearnLevel uses scanned trainer skill")
    eq(exact, true, "marked exact")
end)

-- =========================================================================
-- 4. Planner: chance curve, acquisition, Pass 1, Pass 2, bags, tools, sales
-- =========================================================================
test("planner: Chance curve handles orange, yellow, green, grey, and yellow==grey", function()
    local rec = { k = { 10, 50, 70, 90 } }
    eq(ns.Planner.Chance(rec, 10), 1, "orange = 100%")
    eq(ns.Planner.Chance(rec, 49), 1, "just below yellow = 100%")
    eq(ns.Planner.Chance(rec, 50), 1, "at yellow = 100%")
    near(ns.Planner.Chance(rec, 70), 0.5, 1e-6, "halfway = 50%")
    eq(ns.Planner.Chance(rec, 90), 0, "at grey = 0%")
    eq(ns.Planner.Chance(rec, 120), 0, "above grey = 0%")

    local flat = { k = { 200, 205, 205, 205 } }
    eq(ns.Planner.Chance(flat, 204), 1, "yellow==grey below threshold = 100%")
    eq(ns.Planner.Chance(flat, 205), 0, "yellow==grey at threshold = 0% (no NaN)")
end)

test("planner: Acquisition respects known, planned, rep, books off, vendor vs AH", function()
    local rec = { i = 999100, n = "Test Pattern Craft", k = { 50, 70, 80, 90 }, src = "b", book = 999101, rep = "Thorium Brotherhood", rg = { 2589, 1 } }
    local key = ns.RecipeKey(rec)

    local c, how = ns.Planner.Acquisition("tailoring", rec, { [key] = true }, nil)
    eq(c, 0, "known is free"); eq(how, "known", "how = known")

    c, how = ns.Planner.Acquisition("tailoring", rec, {}, { [key] = true })
    eq(c, 0, "planned is free"); eq(how, "planned", "how = planned")

    c, how = ns.Planner.Acquisition("tailoring", rec, {}, nil)
    eq(c, nil, "rep blocked by default"); eq(how, "rep", "how = rep")

    ns.db.opts.includeRep = true
    ns.db.opts.includeBooks = false
    c, how = ns.Planner.Acquisition("tailoring", rec, {}, nil)
    eq(c, nil, "books off blocks purchase"); eq(how, "books off", "how = books off")

    ns.db.opts.includeBooks = true
    c, how = ns.Planner.Acquisition("tailoring", rec, {}, nil)
    eq(c, nil, "unpriced when neither AH nor vendor"); eq(how, "unpriced", "how = unpriced")

    setAH(999101, 5000, 1)
    c, how = ns.Planner.Acquisition("tailoring", rec, {}, nil)
    eq(c, 5000, "uses AH price"); eq(how, "AH", "how = AH")

    mockVendor[999101] = 3000
    c, how = ns.Planner.Acquisition("tailoring", rec, {}, nil)
    eq(c, 3000, "prefers cheaper vendor"); eq(how, "vendor", "how = vendor")
end)

test("planner: Pass 1 buys profitable pattern, skips overpriced one, lists unpriced in missed", function()
    setAH(2589, 1000, 500) -- Linen Cloth expensive (10s)
    setAH(2996, 2000, 500) -- Bolt of Linen Cloth (20s)
    setAH(2320, 10, 500)   -- Coarse Thread

    local customRec = { i = 999201, n = "Test Cheap Pattern", k = { 40, 50, 55, 60 }, src = "b", book = 999202, req = 40, rg = { 999203, 1 } }
    table.insert(ns.Data.recipes.tailoring, customRec)
    setAH(999203, 50, 500) -- dirt cheap reagent (50c vs 20s+)

    -- (a) Unpriced pattern shows up in plan.missed
    local planMissed = assert(ns.Planner.Build("tailoring", 40, 50))
    local inMissed = false
    for _, m in ipairs(planMissed.missed) do if m.rec == customRec then inMissed = true end end
    ok(inMissed, "unpriced helpful pattern listed in plan.missed")

    -- (b) Cheap pattern (5s) saves > 5s over 10 points -> bought in plan.acquire
    setAH(999202, 500, 1)
    local planBuy = assert(ns.Planner.Build("tailoring", 40, 50))
    local bought = false
    for _, a in ipairs(planBuy.acquire) do if a.rec == customRec and a.how == "AH" then bought = true end end
    ok(bought, "profitable pattern acquired")

    -- (c) Absurdly expensive pattern (500g) -> skipped
    setAH(999202, 5000000, 1)
    local planSkip = assert(ns.Planner.Build("tailoring", 40, 50))
    local skippedBuy = true
    for _, a in ipairs(planSkip.acquire) do if a.rec == customRec then skippedBuy = false end end
    ok(skippedBuy, "unprofitable pattern skipped")

    table.remove(ns.Data.recipes.tailoring)
end)

test("planner: stock reuse, prep crafting, and AH-to-vendor supply spill", function()
    -- Tailoring 1 -> 50: crafts Bolts of Linen Cloth early and reuses them in later steps
    setAH(2589, 100, 500)  -- Linen Cloth @ 1s
    setAH(2996, 1000, 500) -- Bolt of Linen Cloth @ 10s (much pricier than crafting from 2x Linen)
    -- Coarse Thread: vendor is 10c; AH has only 5 @ 4c -> buys 5 on AH, remainder from vendor
    setAH(2320, 4, 5)

    local plan = assert(ns.Planner.Build("tailoring", 1, 50))
    eq(#plan.gaps, 0, "no gaps")

    local thread = assert(findShopRow(plan, 2320), "Coarse Thread in shopping")
    eq(thread.ah, 5, "bought all 5 cheap Coarse Thread from AH")
    ok(thread.vendor > 0, "spilled remaining Coarse Thread to vendor")

    -- Bolts should be crafted (not bought at 10s on AH)
    local boltsShop = findShopRow(plan, 2996)
    eq(boltsShop, nil, "expensive AH Bolts not bought; crafted from Linen Cloth instead")

    -- At skill 50->55 (Bolts are grey), expensive AH Bolts trigger prep crafts from Linen Cloth
    local planPrep = assert(ns.Planner.Build("tailoring", 50, 55))
    local clothPrep = assert(findShopRow(planPrep, 2589), "bought Linen Cloth for prep-crafted Bolts")
    ok(clothPrep.ah > 0, "Linen Cloth bought on AH for prep")
    eq(findShopRow(planPrep, 2996), nil, "did not buy overpriced Bolts on AH")
end)

test("planner: bag inventory counts as free when useBags=true and totals reconcile", function()
    setAH(2589, 500, 500)
    setAH(2320, 10, 500)
    mockSellPrice[2996] = 40
    mockBags[2589] = 10

    local planOn = assert(ns.Planner.Build("tailoring", 1, 20))
    local linenOn = assert(findShopRow(planOn, 2589))
    eq(linenOn.bags, 10, "used 10 Linen Cloth from bags")
    eq(linenOn.ah, 10, "only bought remaining 10 on AH")

    -- Totals identity: net == ah + vendor + recipes - sale
    local t = planOn.totals
    near(t.net, t.ah + t.vendor + t.recipes - t.sale, 1e-4, "totals.net identity")

    ns.db.opts.useBags = false
    local planOff = assert(ns.Planner.Build("tailoring", 1, 20))
    local linenOff = assert(findShopRow(planOff, 2589))
    eq(linenOff.bags, 0, "bags ignored when useBags=false")
    eq(linenOff.ah, 20, "bought all 20 on AH")
end)

test("planner: required tools (owned, soulbound craft, BoE buy vs craft)", function()
    local items = allKnownItems()
    for id in pairs(items) do setAH(id, 200, 500) end

    -- Enchanting: Runed Copper Rod (6218) is soulbound at skill 1
    local planCraft = assert(ns.Planner.Build("enchanting", 1, 20))
    eq(planCraft.tools[1].item, 6218, "Runed Copper Rod listed")
    eq(planCraft.tools[1].action, "craft", "scheduled for craft when unowned")

    mockBags[6218] = 1
    local planHave = assert(ns.Planner.Build("enchanting", 1, 20))
    eq(planHave.tools[1].action, "have", "skipped when already owned")

    -- Engineering: Arclight Spanner (6219) is BoE — cheap on AH => buy instead of craft
    mockBags = {}
    setAH(6219, 50, 5)
    local planBuy = assert(ns.Planner.Build("engineering", 45, 70))
    local spanner
    for _, tl in ipairs(planBuy.tools) do if tl.item == 6219 then spanner = tl end end
    ok(spanner, "Arclight Spanner listed")
    eq(spanner.action, "buy", "bought on AH when cheaper than crafting")

    -- Expensive on AH => craft instead of buy
    setAH(6219, 500000, 5)
    local planCraftBoE = assert(ns.Planner.Build("engineering", 45, 70))
    local spanner2
    for _, tl in ipairs(planCraftBoE.tools) do if tl.item == 6219 then spanner2 = tl end end
    eq(spanner2.action, "craft", "crafted when AH price exceeds craft cost")
end)

-- =========================================================================
-- 5. UI Compute, Render, tooltips & freeze/thaw serialization
-- =========================================================================
test("ui: Compute baseline, Render, step tooltips, and freeze/thaw roundtrip", function()
    setAH(2589, 100, 500)
    setAH(2320, 4, 5)

    local plan = assert(ns.UI.Compute("tailoring", 1, 45))
    eq(plan.baseline, nil, "no baseline when no optional recipes ticked")
    local lines = ns.UI.Render(plan)
    ok(#lines > 15, "rendered plan lines")

    -- Invoke every line tooltip to confirm none error and step tips include Materials total
    local sawStepTip = false
    local tt = {
        buf = {},
        AddLine = function(self, s) self.buf[#self.buf + 1] = stripColor(s) end,
        AddDoubleLine = function(self, l, r) self.buf[#self.buf + 1] = stripColor(l) .. " | " .. stripColor(r) end,
    }
    for _, l in ipairs(lines) do
        if l.tip then
            tt.buf = {}
            l.tip(tt)
            for _, s in ipairs(tt.buf) do
                if s:find("Materials total") then sawStepTip = true end
            end
        end
    end
    ok(sawStepTip, "step tooltip includes 'Materials total'")

    -- Freeze & thaw roundtrip produces identical rendered line count
    local frozen = ns.UI._freeze(plan, "tailoring")
    local byKey = {}
    for _, rec in ipairs(ns.Data.recipes.tailoring) do byKey[ns.RecipeKey(rec)] = rec end
    local thawed = ns.UI._thaw(frozen, byKey)
    local lines2 = ns.UI.Render(thawed)
    eq(#lines2, #lines, "thawed plan renders identical line count")

    -- With an optional recipe ticked, UI.Compute attaches plan.baseline
    local bag = assert(findRecipe("tailoring", "Linen Bag"))
    ns.Planned("tailoring")[ns.RecipeKey(bag)] = true
    local planWithOpt = assert(ns.UI.Compute("tailoring", 1, 45))
    ok(planWithOpt.baseline, "baseline attached when planned recipes exist")
    ok(#ns.UI.Render(planWithOpt) > 15, "plan with baseline renders cleanly")
end)

-- =========================================================================
-- 6. End-to-end 7-profession smoke test (1 -> 300)
-- =========================================================================
test("smoke: all 7 professions plan 1->300 cleanly, render, and freeze/thaw", function()
    local items, books = allKnownItems()
    for id in pairs(items) do
        setAH(id, books[id] and 20000 or 300, 2000)
    end
    for _, prof in ipairs(ns.PROFESSIONS) do
        local plan = assert(ns.UI.Compute(prof, 1, 300), prof)
        eq(#plan.gaps, 0, prof .. " has 0 gaps")
        ok(#plan.steps > 0, prof .. " has steps")
        local lines = ns.UI.Render(plan)
        ok(#lines > 10, prof .. " renders")
        local frozen = ns.UI._freeze(plan, prof)
        local byKey = {}
        for _, rec in ipairs(ns.Data.recipes[prof]) do byKey[ns.RecipeKey(rec)] = rec end
        local thawed = ns.UI._thaw(frozen, byKey)
        eq(#ns.UI.Render(thawed), #lines, prof .. " freeze/thaw parity")
    end
end)

-- =========================================================================
-- 7. Regression tests (ISSUES.md)
-- =========================================================================
local function findRecipeByBook(prof, bookID)
    for _, rec in ipairs(ns.Data.recipes[prof]) do
        if rec.book == bookID then return rec end
    end
end

local function findRecipeByItem(prof, itemID)
    for _, rec in ipairs(ns.Data.recipes[prof]) do
        if rec.i == itemID then return rec end
    end
end

test("issue #1: every recipe in Data/Recipes.lua has a unique RecipeKey per profession", function()
    for prof, list in pairs(ns.Data.recipes) do
        local seen = {}
        for _, rec in ipairs(list) do
            local key = ns.RecipeKey(rec)
            ok(type(key) == "string" and key ~= "", prof .. ": RecipeKey must be a non-empty string")
            if seen[key] then
                error(("%s: duplicate RecipeKey %q shared by %q (book=%s) and %q (book=%s)"):format(
                    prof, key, seen[key].n, tostring(seen[key].book), rec.n, tostring(rec.book)))
            end
            seen[key] = rec
        end
    end
end)

test("issue #1: duplicate-output recipes do not collide in known, planned, or freeze/thaw", function()
    local fireToEarth = assert(findRecipeByBook("alchemy", 13483), "Transmute Fire to Earth")
    local lifeToEarth = assert(findRecipeByBook("alchemy", 13488), "Transmute Life to Earth")
    ok(ns.RecipeKey(fireToEarth) ~= ns.RecipeKey(lifeToEarth), "Essence of Earth recipes have distinct keys")

    -- Marking only Fire->Earth as known must not mark Life->Earth as known
    local known = { [ns.RecipeKey(fireToEarth)] = true }
    local _, howFire = ns.Planner.Acquisition("alchemy", fireToEarth, known, nil)
    local _, howLife = ns.Planner.Acquisition("alchemy", lifeToEarth, known, nil)
    eq(howFire, "known", "Fire->Earth is known")
    ok(howLife ~= "known", "Life->Earth must not be marked known")

    -- Marking only Fire->Earth as planned must not mark Life->Earth as planned
    local planned = { [ns.RecipeKey(fireToEarth)] = true }
    local _, howFireP = ns.Planner.Acquisition("alchemy", fireToEarth, {}, planned)
    local _, howLifeP = ns.Planner.Acquisition("alchemy", lifeToEarth, {}, planned)
    eq(howFireP, "planned", "Fire->Earth is planned")
    ok(howLifeP ~= "planned", "Life->Earth must not be marked planned")

    -- Freeze/thaw must preserve the exact recipe object for both entries
    local sample = { steps = { { rec = fireToEarth }, { rec = lifeToEarth } } }
    local frozen = ns.UI._freeze(sample, "alchemy")
    local byKey = {}
    for _, rec in ipairs(ns.Data.recipes.alchemy) do byKey[ns.RecipeKey(rec)] = rec end
    local thawed = ns.UI._thaw(frozen, byKey)
    eq(thawed.steps[1].rec, fireToEarth, "thawed step 1 preserves Fire->Earth")
    eq(thawed.steps[2].rec, lifeToEarth, "thawed step 2 preserves Life->Earth")
end)

test("issue #1: Scan.TradeSkill distinguishes duplicate-output recipes by spell ID", function()
    local fireToEarth = assert(findRecipeByBook("alchemy", 13483), "Transmute Fire to Earth")
    local lifeToEarth = assert(findRecipeByBook("alchemy", 13488), "Transmute Life to Earth")
    ok(fireToEarth.sp and lifeToEarth.sp, "duplicate-output item recipes must have spell IDs (sp)")
    ok(fireToEarth.sp ~= lifeToEarth.sp, "duplicate-output item recipes must have distinct spell IDs")

    mockTradeSkill = {
        prof = "Alchemy",
        linked = false,
        recipes = {
            [lifeToEarth.sp] = { name = "Transmute: Life to Earth", item = 7076, learned = true, yield = 1 },
        },
    }
    ns.Scan.TradeSkill()
    eq(ns.cdb.known.alchemy[ns.RecipeKey(lifeToEarth)], true, "learned Life->Earth recorded as known")
    eq(ns.cdb.known.alchemy[ns.RecipeKey(fireToEarth)], nil, "unlearned Fire->Earth not marked known")
end)

test("issue #1: Scan.Trainer records skill and cost for all duplicate-name recipes", function()
    local banner1 = assert(findRecipeByItem("tailoring", 279972), "Faction Banner 279972")
    local banner2 = assert(findRecipeByItem("tailoring", 279973), "Faction Banner 279973")
    mockTrainerServices = {
        { name = "Faction Banner", skill = "Tailoring", rank = 20, cost = 500 },
        { name = "Faction Banner", skill = "Tailoring", rank = 20, cost = 500 },
    }
    ns.Scan.Trainer()

    local info1 = ns.db.trainer.tailoring and ns.db.trainer.tailoring[ns.RecipeKey(banner1)]
    local info2 = ns.db.trainer.tailoring and ns.db.trainer.tailoring[ns.RecipeKey(banner2)]
    ok(info1, "first Faction Banner recorded in ns.db.trainer")
    ok(info2, "second Faction Banner recorded in ns.db.trainer")
    eq(info1.cost, 500, "first Faction Banner trainer cost")
    eq(info2.cost, 500, "second Faction Banner trainer cost")

    local cost2, how2 = ns.Planner.Acquisition("tailoring", banner2, {}, nil)
    eq(how2, "trainer", "second Faction Banner acquisition = trainer")
    eq(cost2, 500, "second Faction Banner uses scanned trainer fee")
end)

test("issue #1: ADDON_LOADED migrates unambiguous legacy i: keys and drops ambiguous ones", function()
    local bolt = assert(findRecipe("tailoring", "Bolt of Linen Cloth"))
    local bag = assert(findRecipe("tailoring", "Linen Bag"))
    local fireToEarth = assert(findRecipeByBook("alchemy", 13483))
    local lifeToEarth = assert(findRecipeByBook("alchemy", 13488))

    jewilUI_ProfessionLevelerDB = {
        trainer = { tailoring = { ["i:" .. bag.i] = { skill = 45, cost = 200 } } },
        yields = { tailoring = { ["i:" .. bolt.i] = 3, [ns.RecipeKey(bolt)] = 2 } },
    }
    jewilUI_ProfessionLevelerCharDB = {
        known = {
            tailoring = { ["i:" .. bolt.i] = true },
            alchemy = { ["i:7076"] = true },
        },
        planned = {
            tailoring = { ["i:" .. bag.i] = true },
            alchemy = { ["i:7076"] = true },
        },
    }
    onEvent(frames[1], "ADDON_LOADED", "jewilUI_ProfessionLeveler")

    -- Unambiguous keys migrate to s:<sp> and old i: keys are removed
    eq(ns.db.trainer.tailoring[ns.RecipeKey(bag)].cost, 200, "trainer migrated to spell key")
    eq(ns.db.trainer.tailoring["i:" .. bag.i], nil, "legacy trainer key removed")
    eq(ns.db.yields.tailoring[ns.RecipeKey(bolt)], 2, "existing spell key not overwritten by legacy key")
    eq(ns.db.yields.tailoring["i:" .. bolt.i], nil, "legacy yield key removed")
    eq(ns.cdb.known.tailoring[ns.RecipeKey(bolt)], true, "known migrated to spell key")
    eq(ns.cdb.known.tailoring["i:" .. bolt.i], nil, "legacy known key removed")
    eq(ns.cdb.planned.tailoring[ns.RecipeKey(bag)], true, "planned migrated to spell key")
    eq(ns.cdb.planned.tailoring["i:" .. bag.i], nil, "legacy planned key removed")

    -- Ambiguous legacy key i:7076 is dropped, not copied to either Essence of Earth recipe
    eq(ns.cdb.known.alchemy["i:7076"], nil, "ambiguous known key dropped")
    eq(ns.cdb.known.alchemy[ns.RecipeKey(fireToEarth)], nil, "Fire->Earth not guessed from ambiguous key")
    eq(ns.cdb.known.alchemy[ns.RecipeKey(lifeToEarth)], nil, "Life->Earth not guessed from ambiguous key")
    eq(ns.cdb.planned.alchemy["i:7076"], nil, "ambiguous planned key dropped")
end)

test("issue #1: legacy saved plans thaw unambiguous i: keys and reject ambiguous ones; trainer link disambiguates", function()
    local bolt = assert(findRecipe("tailoring", "Bolt of Linen Cloth"))
    local thawed = ns.UI._thaw({ steps = { { rec = { __rec = "i:" .. bolt.i } } } }, ns.UI._byKey("tailoring"))
    eq(thawed.steps[1].rec, bolt, "unambiguous legacy i: key thaws cleanly")

    local okAmbig = pcall(ns.UI._thaw, { steps = { { rec = { __rec = "i:7076" } } } }, ns.UI._byKey("alchemy"))
    eq(okAmbig, false, "ambiguous legacy i:7076 fails thaw so savedPlan discards stale plan")

    local banner1 = assert(findRecipeByItem("tailoring", 279972))
    local banner2 = assert(findRecipeByItem("tailoring", 279973))
    mockTrainerServices = {
        { name = "Faction Banner", skill = "Tailoring", rank = 20, cost = 400, link = "|Hitem:279972|h[Faction Banner]|h" },
        { name = "Faction Banner", skill = "Tailoring", rank = 25, cost = 600, link = "|Hitem:279973|h[Faction Banner]|h" },
    }
    ns.Scan.Trainer()
    eq(ns.db.trainer.tailoring[ns.RecipeKey(banner1)].cost, 400, "banner 1 cost matched via item link")
    eq(ns.db.trainer.tailoring[ns.RecipeKey(banner2)].cost, 600, "banner 2 cost matched via item link")
    eq(ns.db.trainer.tailoring[ns.RecipeKey(banner2)].skill, 25, "banner 2 skill matched via item link")
end)

test("issue #2: fresh profile uses baked static yields for step output and sale credit", function()
    local roughDyn = assert(findRecipe("engineering", "Rough Dynamite"))
    local lightShot = assert(findRecipe("engineering", "Crafted Light Shot"))
    local coarseDyn = assert(findRecipe("engineering", "Coarse Dynamite"))

    -- Fixed yield = 2 (Rough Dynamite): 10 orange crafts -> 20 items, sale credit = 20 * 30c
    setAH(4357, 50, 500) -- Rough Blasting Powder
    setAH(2589, 50, 500) -- Linen Cloth
    mockSellPrice[roughDyn.i] = 30
    local planDyn = assert(ns.Planner.Build("engineering", 1, 11))
    eq(#planDyn.steps, 1, "single Rough Dynamite step")
    eq(planDyn.steps[1].rec, roughDyn, "chose Rough Dynamite")
    near(planDyn.steps[1].crafts, 10, 1e-6, "10 crafts")
    near(planDyn.steps[1].made, 20, 1e-6, "Rough Dynamite makes 2 per craft without scan")
    near(planDyn.totals.sale, 600, 1e-6, "sale credit uses baked yield 2")

    -- Fixed yield = 200 (Crafted Light Shot): 10 orange crafts -> 2000 items, sale credit = 2000 * 1c
    resetEnv()
    setAH(4357, 50, 500) -- Rough Blasting Powder
    setAH(2840, 50, 500) -- Copper Bar
    mockSellPrice[lightShot.i] = 1
    local planShot = assert(ns.Planner.Build("engineering", 1, 11))
    eq(#planShot.steps, 1, "single Crafted Light Shot step")
    eq(planShot.steps[1].rec, lightShot, "chose Crafted Light Shot")
    near(planShot.steps[1].crafts, 10, 1e-6, "10 crafts")
    near(planShot.steps[1].made, 2000, 1e-6, "Crafted Light Shot makes 200 per craft without scan")
    near(planShot.totals.sale, 2000, 1e-6, "sale credit uses baked yield 200")

    -- Variable yield 1-3, expected average = 2 (Coarse Dynamite): 10 orange crafts -> 20 items
    resetEnv()
    mockBags[6219] = 1   -- Arclight Spanner already owned
    setAH(4364, 50, 500) -- Coarse Blasting Powder
    setAH(2589, 50, 500) -- Linen Cloth
    mockSellPrice[coarseDyn.i] = 20
    local planCoarse = assert(ns.Planner.Build("engineering", 75, 85))
    eq(#planCoarse.steps, 1, "single Coarse Dynamite step")
    eq(planCoarse.steps[1].rec, coarseDyn, "chose Coarse Dynamite")
    near(planCoarse.steps[1].crafts, 10, 1e-6, "10 crafts")
    near(planCoarse.steps[1].made, 20, 1e-6, "Coarse Dynamite expected yield is 2 without scan")
    near(planCoarse.totals.sale, 400, 1e-6, "sale credit uses baked expected yield 2")
end)

test("issue #2: fresh profile uses baked static yields for intermediate costing and prep crafts", function()
    -- Fire Oil (yield = 2) uses 2x Firefin Snapper (100c) + 1x Empty Vial (4c vendor seed) = 204c/craft = 102c/unit.
    -- AH price for Fire Oil is 150c: cheaper to craft at yield=2 (102c < 150c), but looks pricier at yield=1 (204c > 150c).
    local fireProt = assert(findRecipe("alchemy", "Fire Protection Potion"))
    ns.cdb.known.alchemy = { [ns.RecipeKey(fireProt)] = true }
    setAH(4402, 100, 500) -- Small Flame Sac
    setAH(6359, 100, 500) -- Firefin Snapper
    setAH(6371, 150, 500) -- Fire Oil on AH (between 102c and 204c)

    -- Alchemy 170->180: Fire Oil is grey (170); Fire Protection Potion is orange (10 crafts = 10 Fire Oil needed)
    local plan = assert(ns.Planner.Build("alchemy", 170, 180))
    eq(#plan.gaps, 0, "no gaps")
    eq(plan.steps[1].rec, fireProt, "chose Fire Protection Potion")
    eq(findShopRow(plan, 6371), nil, "Fire Oil prep-crafted instead of bought at 150c")

    -- 10 Fire Oil at yield=2 requires 5 crafts = 10 Firefin Snapper + 5 Empty Vial (not 20 / 10)
    local snapper = assert(findShopRow(plan, 6359), "bought Firefin Snapper for prep-crafted Fire Oil")
    near(snapper.ah, 10, 1e-6, "10 Firefin Snapper for 5 Fire Oil crafts")
    local vial = assert(findShopRow(plan, 3371), "bought Empty Vial for prep-crafted Fire Oil")
    near(vial.vendor, 5, 1e-6, "5 Empty Vial for 5 Fire Oil crafts")
end)

test("issue #2: Scan.TradeSkill averages variable yields and does not downgrade static yields", function()
    local bolt = assert(findRecipe("tailoring", "Bolt of Linen Cloth"))
    local bag = assert(findRecipe("tailoring", "Linen Bag"))
    mockTradeSkill = {
        prof = "Tailoring",
        linked = false,
        recipes = {
            [bolt.sp] = { name = bolt.n, item = bolt.i, learned = true, yieldMin = 1, yieldMax = 3 },
            [bag.sp] = { name = bag.n, item = bag.i, learned = true, yieldMin = 2, yieldMax = 5 },
        },
    }
    ns.Scan.TradeSkill()
    near(ns.db.yields.tailoring[ns.RecipeKey(bolt)], 2, 1e-6, "1-3 averages to 2")
    near(ns.db.yields.tailoring[ns.RecipeKey(bag)], 3.5, 1e-6, "2-5 averages to 3.5")

    -- Scanning Iron Grenade (2-4, avg 3) clears any stale pre-fix yield and keeps effective yield at 3
    local grenade = assert(findRecipe("engineering", "Iron Grenade"))
    ns.db.yields.engineering = { [ns.RecipeKey(grenade)] = 2 }
    mockTradeSkill = {
        prof = "Engineering",
        linked = false,
        recipes = {
            [grenade.sp] = { name = grenade.n, item = grenade.i, learned = true, yieldMin = 2, yieldMax = 4 },
        },
    }
    ns.Scan.TradeSkill()
    eq(ns.db.yields.engineering[ns.RecipeKey(grenade)], nil, "stale pre-fix yield cleared when live average matches static yield")
    mockBags[6219] = 1   -- Arclight Spanner
    setAH(3575, 100, 500) -- Iron Bar
    setAH(4377, 100, 500) -- Heavy Blasting Powder
    setAH(4306, 100, 500) -- Silk Cloth
    local plan = assert(ns.Planner.Build("engineering", 175, 176))
    eq(plan.steps[1].rec, grenade, "chose Iron Grenade")
    near(plan.steps[1].crafts, 1, 1e-6, "1 craft at skill 175")
    near(plan.steps[1].made, 3, 1e-6, "Iron Grenade yields average 3 after scanning 2-4")
end)

test("issue #2: scanned tradeskill yields override baked static yields", function()
    local roughDyn = assert(findRecipe("engineering", "Rough Dynamite"))
    setAH(4357, 50, 500) -- Rough Blasting Powder
    setAH(2589, 50, 500) -- Linen Cloth

    -- Live scan reports higher yield (4 instead of static 2)
    mockTradeSkill = {
        prof = "Engineering",
        linked = false,
        recipes = {
            [roughDyn.sp] = { name = roughDyn.n, item = roughDyn.i, learned = true, yieldMin = 4, yieldMax = 4 },
        },
    }
    ns.Scan.TradeSkill()
    local planHigh = assert(ns.Planner.Build("engineering", 1, 11))
    near(planHigh.steps[1].made, 40, 1e-6, "scanned yield 4 overrides static yield 2")

    -- Live scan reports lower yield (1 instead of static 2)
    mockTradeSkill.recipes[roughDyn.sp] = { name = roughDyn.n, item = roughDyn.i, learned = true, yieldMin = 1, yieldMax = 1 }
    ns.Scan.TradeSkill()
    local planLow = assert(ns.Planner.Build("engineering", 1, 11))
    near(planLow.steps[1].made, 10, 1e-6, "scanned yield 1 overrides static yield 2")
end)

-- Issue #3: a saved plan that names a recipe key the current data no longer has.
local function stalePlan(key)
    return { start = 1, target = 45, builtAt = 1, steps = { { rec = { __rec = key }, crafts = 3 } } }
end

test("issue #3: savedPlan returns nil for a stored plan with an unknown recipe key", function()
    ns.UI._live.tailoring = nil
    ns.cdb.plans = { tailoring = stalePlan("s:999999999") }
    eq(ns.UI._savedPlan("tailoring"), nil, "stale plan is not returned")
    eq(ns.UI._live.tailoring, nil, "stale plan is not cached as live")
end)

test("issue #3: savedPlan discards a stored plan with an unknown recipe key", function()
    ns.UI._live.tailoring = nil
    ns.cdb.plans = { tailoring = stalePlan("s:999999999") }
    ns.UI._savedPlan("tailoring")
    eq(ns.cdb.plans.tailoring, nil, "stale plan is removed from saved variables")
    eq(#prints, 1, "one chat message")
    ok(stripColor(prints[1]):find("Saved Tailoring plan used a recipe that no longer exists", 1, true),
        "chat message explains the missing recipe: " .. tostring(prints[1]))
    -- Second lookup finds nothing stored: no re-thaw, no repeated message
    eq(ns.UI._savedPlan("tailoring"), nil, "nothing left to load")
    eq(#prints, 1, "message is not repeated")
end)

test("issue #3: savedPlan discards a stored plan that has no steps", function()
    ns.UI._live.tailoring = nil
    ns.cdb.plans = { tailoring = { start = 1, target = 45, builtAt = 1 } }
    eq(ns.UI._savedPlan("tailoring"), nil, "plan without steps is not returned")
    eq(ns.cdb.plans.tailoring, nil, "plan without steps is removed from saved variables")
    ok(stripColor(prints[1] or ""):find("Saved Tailoring plan could not be read", 1, true),
        "chat message for unreadable plan: " .. tostring(prints[1]))
end)

test("issue #3: one stale profession plan does not affect other professions", function()
    ns.UI._live.tailoring, ns.UI._live.alchemy = nil, nil
    local bolt = assert(findRecipe("tailoring", "Bolt of Linen Cloth"))
    ns.cdb.plans = {
        tailoring = stalePlan(ns.RecipeKey(bolt)),
        alchemy = stalePlan("s:999999999"),
    }
    local plan = ns.UI._savedPlan("tailoring")
    ok(plan, "valid tailoring plan loads")
    eq(plan.steps[1].rec, bolt, "valid tailoring plan resolves its recipe")
    eq(ns.UI._savedPlan("alchemy"), nil, "stale alchemy plan is rejected")
    eq(ns.cdb.plans.alchemy, nil, "stale alchemy plan is removed")
    ok(ns.cdb.plans.tailoring, "valid tailoring plan stays stored")
    eq(#prints, 1, "only the stale alchemy plan prints a message")
    ns.UI._live.tailoring = nil
end)


-- Issue #4: shared scarce base materials across reagents and nested prep crafts.
test("issue #4: direct and prep-crafted reagents sharing scarce base material do not crash", function()
    local silverContact = assert(findRecipe("engineering", "Silver Contact"))
    -- Skill 110->111: Copper Modulator (chance 0.5 => 2 crafts) needs 4x Handful of Copper Bolts
    -- (4 Copper Bars via prep) + 2x Copper Bar directly = 6 Copper Bars total. Only 4 exist.
    mockBags[6219] = 1     -- Arclight Spanner already owned
    setAH(2840, 10, 4)     -- Copper Bar: enough for Bolts OR direct bars, not both
    setAH(2589, 10, 50)    -- Linen Cloth

    -- (a) No alternative recipe: must return a clean gap with no leaked shopping items
    local planGap = assert(ns.Planner.Build("engineering", 110, 111))
    eq(#planGap.steps, 0, "impossible Copper Modulator is not scheduled")
    eq(#planGap.gaps, 1, "skill 110 recorded as a gap")
    eq(planGap.gaps[1], 110, "gap is at skill 110")
    eq(#planGap.shopping, 0, "no partial materials leaked into shopping list")

    -- (b) Valid pricier alternative exists: must skip impossible Copper Modulator and pick it
    setAH(2842, 500, 10)   -- Silver Bar for Silver Contact (1 craft @ 500c)
    local planAlt = assert(ns.Planner.Build("engineering", 110, 111))
    eq(#planAlt.gaps, 0, "no gaps when valid alternative exists")
    eq(planAlt.steps[1].rec, silverContact, "fell back to valid Silver Contact")
    eq(findShopRow(planAlt, 2840), nil, "no Copper Bars leaked from rejected Copper Modulator")
end)

test("issue #4: nested prep craft sharing scarce base material does not silently drop reagents", function()
    local seaforium = assert(findRecipe("engineering", "Small Seaforium Charge"))
    -- Skill 125->126: Small Seaforium Charge (1 craft) needs 1x Copper Modulator (grey at 125).
    -- Prep-crafting Copper Modulator needs 2x Handful of Copper Bolts (2 Copper Bars) + 1x Copper Bar
    -- directly = 3 Copper Bars total, while only 2 Copper Bars exist on AH.
    ns.cdb.known.engineering = { [ns.RecipeKey(seaforium)] = true }
    mockBags[6219] = 1     -- Arclight Spanner
    setAH(2840, 100, 2)    -- Copper Bar: only 2 available (need 3)
    setAH(2589, 50, 50)    -- Linen Cloth
    setAH(4364, 100, 50)   -- Coarse Blasting Powder
    setAH(2318, 100, 50)   -- Light Leather

    -- (a) Copper Modulator not on AH: prep craft is impossible, must not drop the 3rd Copper Bar
    local planGap = assert(ns.Planner.Build("engineering", 125, 126))
    eq(#planGap.steps, 0, "must not schedule Small Seaforium Charge with impossible prep craft")
    eq(#planGap.gaps, 1, "skill 125 recorded as a gap")
    eq(#planGap.shopping, 0, "no partial materials leaked into shopping list")

    -- (b) Copper Modulator IS on AH (2000c): impossible prep must fall back to buying on AH
    setAH(4363, 2000, 5)   -- Copper Modulator on AH
    local planBuy = assert(ns.Planner.Build("engineering", 125, 126))
    eq(#planBuy.gaps, 0, "no gaps when Copper Modulator can be bought on AH")
    eq(planBuy.steps[1].rec, seaforium, "crafted Small Seaforium Charge")
    local modRow = assert(findShopRow(planBuy, 4363), "bought Copper Modulator on AH")
    eq(modRow.ah, 1, "bought 1 Copper Modulator on AH")
    eq(findShopRow(planBuy, 2840), nil, "did not attempt partial prep craft with Copper Bars")
end)

test("issue #4: sibling prep crafts sharing scarce base material do not crash or lose reagents", function()
    local sheep = assert(findRecipe("engineering", "Explosive Sheep"))
    -- Skill 195->196: Explosive Sheep (chance 0.2 => 5 crafts) needs 5x Bronze Framework
    -- (10 Bronze Bars) and 5x Whirring Bronze Gizmo (10 Bronze Bars) = 20 Bronze Bars total.
    mockBags[6219] = 1     -- Arclight Spanner
    setAH(2841, 100, 10)   -- Bronze Bar: enough for 5 Frameworks OR 5 Gizmos, not both
    setAH(2319, 50, 50)    -- Medium Leather
    setAH(2592, 50, 50)    -- Wool Cloth
    setAH(4377, 50, 50)    -- Heavy Blasting Powder

    -- (a) Neither intermediate on AH: must not crash in record
    local planGap = assert(ns.Planner.Build("engineering", 195, 196))
    eq(#planGap.steps, 0, "impossible Explosive Sheep is not scheduled")
    eq(#planGap.gaps, 1, "skill 195 recorded as a gap")
    eq(#planGap.shopping, 0, "no partial materials leaked into shopping list")

    -- (b) Whirring Bronze Gizmo on AH: prep-crafts 5 Frameworks (10 Bronze Bars) and buys 5 Gizmos
    setAH(4375, 1000, 10)  -- Whirring Bronze Gizmo on AH
    local planMixed = assert(ns.Planner.Build("engineering", 195, 196))
    eq(#planMixed.gaps, 0, "no gaps when second intermediate can be bought on AH")
    eq(planMixed.steps[1].rec, sheep, "crafted Explosive Sheep")
    local barRow = assert(findShopRow(planMixed, 2841), "bought Bronze Bars for Frameworks")
    eq(barRow.ah, 10, "used all 10 Bronze Bars for 5 Bronze Frameworks")
    local gizmoRow = assert(findShopRow(planMixed, 4375), "bought Whirring Bronze Gizmos on AH")
    eq(gizmoRow.ah, 5, "bought 5 Whirring Bronze Gizmos on AH")
end)

test("issue #4: dry run does not double-count shared bagged supply across reagents", function()
    local silverContact = assert(findRecipe("engineering", "Silver Contact"))
    -- Skill 110->111: Copper Modulator (chance 0.5 => 2 crafts) needs 4x Bolts (4 Copper Bars) +
    -- 2x Copper Bar + 4x Linen Cloth. With 4 free Copper Bars in bags and AH Copper Bars at 1000c,
    -- real cost is 2040c, not 40c. Silver Contact (1x Silver Bar @ 500c) is much cheaper.
    mockBags[6219] = 1     -- Arclight Spanner
    mockBags[2840] = 4     -- 4 free Copper Bars in bags
    setAH(2840, 1000, 50)  -- Additional Copper Bars cost 1000c each
    setAH(2589, 10, 50)    -- Linen Cloth
    setAH(2842, 500, 10)   -- Silver Bar for Silver Contact

    local plan = assert(ns.Planner.Build("engineering", 110, 111))
    eq(#plan.gaps, 0, "no gaps")
    eq(plan.steps[1].rec, silverContact, "chose cheaper Silver Contact instead of double-counted Copper Modulator")
    eq(plan.totals.ah, 500, "spent 500c instead of 2040c")
end)


test("planner: alchemy crafts Philosopher's Stone when target >= 275 (orange 225-239)", function()
    local items, books = allKnownItems()
    for id in pairs(items) do setAH(id, books[id] and 5000 or 200, 500) end
    local stone = assert(findRecipe("alchemy", "Philosopher's Stone"))

    -- Target 274: below 275 threshold -> not scheduled
    local planBelow = assert(ns.Planner.Build("alchemy", 200, 274))
    eq(#planBelow.tools, 0, "no required tools when target < 275")

    -- Target 275: scheduled as a required tool while orange (225-239)
    local plan275 = assert(ns.Planner.Build("alchemy", 200, 275))
    eq(#plan275.tools, 1, "Philosopher's Stone listed at target 275")
    eq(plan275.tools[1].item, 9149, "item is Philosopher's Stone")
    eq(plan275.tools[1].action, "craft", "scheduled for craft when unowned")
    ok(plan275.tools[1].at >= 225 and plan275.tools[1].at <= 239,
        "scheduled in orange window 225-239 (got " .. tostring(plan275.tools[1].at) .. ")")

    local toolStep
    for _, st in ipairs(plan275.steps) do
        if st.tool and st.rec == stone then toolStep = st end
    end
    ok(toolStep, "Philosopher's Stone craft step present")
    eq(toolStep.chanceFrom, 1, "crafted while orange (100% skill-up)")
    eq(toolStep.to, toolStep.from + 1, "gives 1 skill point")
    near(toolStep.crafts, 1, 1e-6, "crafts exactly 1")

    -- Recipe: Philosopher's Stone included in acquire even when includeBooks=false
    ns.db.opts.includeBooks = false
    local planNoBooks = assert(ns.Planner.Build("alchemy", 200, 300))
    eq(planNoBooks.tools[1].action, "craft", "still crafted when includeBooks=false")
    local hasBook = false
    for _, a in ipairs(planNoBooks.acquire) do
        if a.rec == stone and a.how == "AH" and a.cost == 5000 then hasBook = true end
    end
    ok(hasBook, "Recipe: Philosopher's Stone included in plan.acquire")

    -- Already owned (even with useBags=false): marked 'have', not crafted
    ns.db.opts.useBags = false
    mockBags[9149] = 1
    local planHave = assert(ns.Planner.Build("alchemy", 200, 300))
    eq(planHave.tools[1].action, "have", "skipped when already owned")
    for _, st in ipairs(planHave.steps) do
        ok(st.rec ~= stone, "no craft step when already owned")
    end
end)

test("planner: Philosopher's Stone picks costliest orange skill in 225-239 and handles grey start >= 280", function()
    local items, books = allKnownItems()
    for id in pairs(items) do setAH(id, books[id] and 5000 or 1000, 500) end
    local stone = assert(findRecipe("alchemy", "Philosopher's Stone"))

    -- Make Draught of Detect Undead (learn 230, orange 230-244: Arthas' Tears 8836 + Crystal Vial 8925)
    -- super cheap, while 225-229 uses Greater Mana Potion (yellow 220, rising cost through 229).
    -- Costliest point in 225-239 should be 229 (right before Detect Undead unlocks at 230).
    setAH(8836, 10, 500)   -- Arthas' Tears (cheap!)
    setAH(3358, 500, 500)  -- Khadgar's Whisker
    setAH(3821, 500, 500)  -- Goldthorn
    setAH(7972, 5000, 500) -- Ichor of Undeath (expensive)
    setAH(249274, 5000, 500) -- Viridian Dye mat (expensive)
    setAH(8831, 5000, 500) -- Purple Lotus (expensive)
    setAH(4625, 5000, 500) -- Firebloom (expensive)
    setAH(3575, 5000, 500) -- Iron Bar
    setAH(9262, 5000, 500) -- Black Vitriol
    ns.db.opts.includeBooks = false -- only trainer recipes + required tool

    local planOpt = assert(ns.Planner.Build("alchemy", 220, 275))
    eq(planOpt.tools[1].at, 229, "placed at costliest orange skill (229, right before cheaper 230 recipe)")

    -- Starting at 280 (grey for Philosopher's Stone) without owning it:
    -- still crafts it at 280, includes its recipe in acquire & totals.recipes, and renders tooltip cleanly.
    local planGrey = assert(ns.Planner.Build("alchemy", 280, 300))
    eq(planGrey.tools[1].action, "craft", "crafted even when starting at 280")
    eq(planGrey.tools[1].at, 280, "crafted at start skill 280")
    local hasBook = false
    for _, a in ipairs(planGrey.acquire) do
        if a.rec == stone and a.cost == 5000 then hasBook = true end
    end
    ok(hasBook, "Recipe: Philosopher's Stone still in plan.acquire when starting past grey threshold")
    ok(planGrey.totals.recipes >= 5000, "recipe cost counted in totals.recipes")

    local lines = ns.UI.Render(planGrey)
    local tt = {
        buf = {},
        AddLine = function(self, s) self.buf[#self.buf + 1] = stripColor(s) end,
        AddDoubleLine = function(self, l, r) self.buf[#self.buf + 1] = stripColor(l) .. " | " .. stripColor(r) end,
    }
    local sawGreyTip = false
    for _, l in ipairs(lines) do
        ok(stripColor(l.text or "") ~= "Required tools", "Required tools section removed from shopping list")
        if l.tip then
            tt.buf = {}
            l.tip(tt)
            if tt.buf[1] == "Philosopher's Stone  (280)" then
                sawGreyTip = true
                eq(tt.buf[2], "Chance to skill up: 0% at 280", "grey tool tooltip shows single skill")
            end
        end
    end
    ok(sawGreyTip, "rendered tooltip for grey Philosopher's Stone step")

    -- Unpriced required-tool recipe still appears in Recipes table as Not on AH
    mockAucPrice[9303] = nil
    local planUnpriced = assert(ns.Planner.Build("alchemy", 220, 275))
    local sawUnpricedBook = false
    for _, l in ipairs(ns.UI.Render(planUnpriced)) do
        if l.item == 9303 and l.cols and stripColor(l.cols[3][1]) == "Not on AH" then
            sawUnpricedBook = true
        end
    end
    ok(sawUnpricedBook, "unpriced required-tool recipe shown in Recipes table")
end)

-- Summary ------------------------------------------------------------------
local elapsed = os.clock() * 1000
realPrint(("\n%d passed, %d failed%s (%.0f ms)"):format(
    passed, failed, skipped > 0 and (", " .. skipped .. " skipped") or "", elapsed))
if failed > 0 then os.exit(1) end
