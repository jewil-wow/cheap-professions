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
        return r and { outputItemID = r.item, quantityMin = r.yield or 1 } or nil
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

-- Summary ------------------------------------------------------------------
local elapsed = os.clock() * 1000
realPrint(("\n%d passed, %d failed%s (%.0f ms)"):format(
    passed, failed, skipped > 0 and (", " .. skipped .. " skipped") or "", elapsed))
if failed > 0 then os.exit(1) end
