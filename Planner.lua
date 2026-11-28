-- Planner.lua: cheapest expected path from a skill level to the target.
--
-- Expected crafts for one skill point with recipe r at skill s = 1 / chance(r, s), where
-- chance is 1 below yellow, (grey - s) / (grey - yellow) between yellow and grey, 0 at grey.
--
-- Pass 1 (which recipes to acquire): with unlimited supply, start from the free recipes
-- (known, automatic, trainer) and repeatedly add the purchasable recipe (pattern from
-- AH/vendor, or a trainer fee) that saves the most over the whole path, while it saves more
-- than it costs.
--
-- Pass 2 (allocation): walk skill points in order and pick the cheapest recipe given what
-- has been used so far.
--   * Everything crafted goes into stock. Later steps take reagents from stock first
--     (free, already paid for), then bags, then the cheaper of AH (up to the listed
--     quantity) and vendor. Only stock still unused at the end is sold.
--   * When choosing a recipe, output that later steps will need is valued at what it would
--     cost to get it later (buy or craft), not at its vendor price. So crafting needed
--     intermediates (leather, bolts...) while they still give skill-ups is nearly free and
--     gets scheduled as steps.
--   * If stock runs short, the intermediate is crafted right before the step that needs it
--     ("prep" crafts, no skill-ups counted).
--   * Future need depends on the plan itself, so allocation runs a few times, each using the
--     previous run's usage, and the cheapest result is kept.
local _, ns = ...

local Planner = {}
ns.Planner = Planner

local INF = math.huge
local MAX_DEPTH = 2
local ITERATIONS = 3

function Planner.Chance(rec, skill)
    local y, gr = rec.k[2], rec.k[4]
    if skill >= gr then return 0 end
    if skill < y then return 1 end
    return (gr - skill) / (gr - y)
end

-- Trainer info shipped with the addon (Data/TrainerData.lua): skill to learn rec, or nil.
-- Names are matched ignoring case (the trainer shows "Double-stitched", the data "Double-Stitched").
function Planner.ShippedTrainer(prof, rec)
    local td = ns.Data.trainerData and ns.Data.trainerData[prof]
    if not td then return end
    if not td.lower then
        td.lower = {}
        for name, skill in pairs(td.recipes) do td.lower[name:lower()] = skill end
    end
    return td.lower[rec.n:lower()]
end

-- Specialization a trainer recipe needs ("Gnomish Engineer"...), or nil.
function Planner.ShippedSpec(prof, rec)
    local td = ns.Data.trainerData and ns.Data.trainerData[prof]
    if not (td and td.specs) then return end
    if not td.specsLower then
        td.specsLower = {}
        for name, spec in pairs(td.specs) do td.specsLower[name:lower()] = spec end
    end
    return td.specsLower[rec.n:lower()]
end

local function trainerComplete(prof)
    local td = ns.Data.trainerData and ns.Data.trainerData[prof]
    return td and td.complete
end

-- Skill needed to learn, and whether that number is exact.
-- Order: your own trainer scans, trainer data shipped with the addon, the recipe data, a guess.
function Planner.LearnLevel(prof, rec)
    local t = ns.db.trainer[prof] and ns.db.trainer[prof][ns.RecipeKey(rec)]
    if t and t.skill then return t.skill, true end
    local shipped = Planner.ShippedTrainer(prof, rec)
    if shipped then return shipped, true end
    if rec.k[1] then return rec.k[1], true end
    -- Trainer recipe with no trainer data yet: rough guess.
    return math.max(1, rec.k[2] - 20), false
end

-- What it takes to be able to craft rec: cost (nil = not obtainable / excluded) and how.
function Planner.Acquisition(prof, rec, known, planned)
    local key = ns.RecipeKey(rec)
    if known[key] then return 0, "known" end
    if planned and planned[key] then return 0, "planned" end
    if rec.src == "a" then return 0, "auto" end
    -- Needs a specialization: not assumed. It shows under Optional Recipes; tick it if you have it.
    if Planner.ShippedSpec(prof, rec) then return nil, "spec" end
    local scanned = ns.db.trainer[prof] and ns.db.trainer[prof][key]
    if scanned or Planner.ShippedTrainer(prof, rec) then
        -- taught by a trainer (some recipes that also have a pattern are, in Forever)
        return (scanned and scanned.cost) or 0, "trainer"
    end
    if rec.src == "t" then
        -- No pattern item. With a complete trainer list that doesn't include it, it comes
        -- from somewhere else (quest, specialization trainer...).
        if trainerComplete(prof) then return nil, "special" end
        return 0, "trainer"
    end
    local opts = ns.db.opts
    if rec.rep and not opts.includeRep then return nil, "rep" end
    if not opts.includeBooks then return nil, "books off" end
    local ah = ns.Prices.AH(rec.book)
    local v = ns.Prices.Vendor(rec.book)
    if v and (not ah or v <= ah) then return v, "vendor" end
    if ah then return ah, "AH" end
    return nil, "unpriced"
end

local function yieldOf(prof, rec)
    local y = ns.db.yields[prof] and ns.db.yields[prof][ns.RecipeKey(rec)]
    return y or rec.y or 1
end

local function addTo(t, k, v)
    t[k] = (t[k] or 0) + v
end

---------------------------------------------------------------------------
-- Plan context
---------------------------------------------------------------------------
local Ctx = {}
Ctx.__index = Ctx

local function resetUsage(st)
    st.usedBags, st.usedAH, st.usedVendor = 0, 0, 0
    st.stock, st.usedStock = 0, 0 -- crafted by earlier steps
end

function Ctx:Supply(item)
    local st = self.supply[item]
    if st then return st end
    local ah, age, qty = ns.Prices.AH(item)
    local vendor, seed = ns.Prices.Vendor(item)
    st = {
        ah = ah, age = age, ahQty = ah and (qty or INF) or 0, qtyKnown = qty ~= nil,
        vendor = vendor, seed = seed,
        bags = ns.Prices.Bags(item),
    }
    resetUsage(st)
    self.supply[item] = st
    return st
end

function Ctx:SaleOf(item)
    local v = self.itemSale[item]
    if v == nil then
        local src, info
        v, src, info = ns.Prices.SaleValue(item)
        self.itemSale[item], self.itemSaleSrc[item] = v, src
        if info then
            info.src = src
            self.itemSaleInfo[item] = info
        end
    end
    return v, self.itemSaleSrc[item]
end

-- Unlimited-supply unit price (ignores bags/stock so pass 1 is not skewed by inventory).
function Ctx:BuyUnit(item)
    local st = self:Supply(item)
    local p = INF
    if st.ah then p = st.ah end
    if st.vendor and st.vendor < p then p = st.vendor end
    return p
end

-- Recipe that can make `item` at skill s from the allowed set, or nil.
function Ctx:Maker(item, s)
    local list = self.makers[item]
    if not list then return end
    local best, bestLearn
    for _, rec in ipairs(list) do
        if self.allowed[rec] and self.learn[rec] <= s then
            if not best or self.learn[rec] < bestLearn then best, bestLearn = rec, self.learn[rec] end
        end
    end
    return best
end

-- Unlimited-supply cost of one unit of `item` at skill s: buy, or craft if cheaper.
function Ctx:UnitCost(item, s, depth)
    local buy = self:BuyUnit(item)
    if depth >= MAX_DEPTH then return buy end
    local maker = self:Maker(item, s)
    if maker then
        local c = 0
        local rg = maker.rg
        for j = 1, #rg, 2 do
            c = c + self:UnitCost(rg[j], s, depth + 1) * rg[j + 1]
            if c == INF then break end
        end
        c = c / yieldOf(self.prof, maker)
        if c < buy then return c end
    end
    return buy
end

-- Unlimited-supply net cost of one craft of rec at skill s (pass 1 only).
function Ctx:CraftCost(rec, s)
    local c = 0
    local rg = rec.rg
    for j = 1, #rg, 2 do
        c = c + self:UnitCost(rg[j], s, 0) * rg[j + 1]
        if c == INF then return INF end
    end
    return c - self.sale[rec] * yieldOf(self.prof, rec)
end

-- Free units available now: earlier crafts first, then bags.
local function freeSplit(st, n)
    local fromStock = math.min(n, math.max(0, st.stock - st.usedStock))
    local fromBags = math.min(n - fromStock, math.max(0, st.bags - st.usedBags))
    return fromStock, fromBags
end

-- Buy n units: the cheaper of AH/vendor first, then the other. INF if it can't be covered.
local function buySplit(st, n)
    local a, v, rem = 0, 0, n
    local ahLeft = st.ah and math.max(0, st.ahQty - st.usedAH) or 0
    if st.vendor and (not st.ah or st.vendor <= st.ah) then
        v, rem = rem, 0
    else
        a = math.min(rem, ahLeft)
        rem = rem - a
        if rem > 0 and st.vendor then v, rem = rem, 0 end
    end
    if rem > 1e-9 then return INF end
    return a * (st.ah or 0) + v * (st.vendor or 0), a, v
end

-- Savepoint / undo stack for tentative supply usage during dry runs.
function Ctx:SaveUsage(st)
    local u, n = self.undo, self.undoTop
    u[n + 1] = st
    u[n + 2] = st.usedStock
    u[n + 3] = st.usedBags
    u[n + 4] = st.usedAH
    u[n + 5] = st.usedVendor
    self.undoTop = n + 5
end

function Ctx:RevertUsage(mark)
    local u = self.undo
    for i = self.undoTop, mark + 1, -5 do
        local st = u[i - 4]
        st.usedStock = u[i - 3]
        st.usedBags = u[i - 2]
        st.usedAH = u[i - 1]
        st.usedVendor = u[i]
        u[i - 4] = nil
    end
    self.undoTop = mark
end

-- Supply-aware cost of `qty` units of item at skill s.
-- When commit is false, tentatively updates st.used* (logged to self.undo) so sibling
-- reagents in the same craft see reduced supply; callers revert self.undo after evaluating.
function Ctx:ReagentCost(item, qty, s, depth, commit)
    local st = self:Supply(item)
    local fromStock, fromBags = freeSplit(st, qty)
    local rest = qty - fromStock - fromBags
    local stockBefore = st.usedStock

    local buyCost, a, v = 0, 0, 0
    local craftCost, maker = INF, nil
    local probeMark
    if rest > 1e-9 then
        buyCost, a, v = buySplit(st, rest)
        if depth < MAX_DEPTH then
            maker = self:Maker(item, s)
            if maker then
                probeMark = self.undoTop
                if fromStock > 0 or fromBags > 0 then
                    self:SaveUsage(st)
                    st.usedStock = st.usedStock + fromStock
                    st.usedBags = st.usedBags + fromBags
                end
                local crafts = rest / yieldOf(self.prof, maker)
                craftCost = 0
                local rg = maker.rg
                for j = 1, #rg, 2 do
                    craftCost = craftCost + self:ReagentCost(rg[j], rg[j + 1] * crafts, s, depth + 1, false)
                    if craftCost == INF then break end
                end
            end
        end
    end

    local cost = math.min(buyCost, craftCost)
    if cost == INF then
        if probeMark then self:RevertUsage(probeMark) end
        return cost
    end
    if not commit then
        if probeMark and buyCost <= craftCost then
            self:RevertUsage(probeMark)
            probeMark = nil
        end
        if not probeMark then
            if fromStock > 0 or fromBags > 0 or a > 0 or v > 0 then
                self:SaveUsage(st)
                st.usedStock = st.usedStock + fromStock
                st.usedBags = st.usedBags + fromBags
                st.usedAH = st.usedAH + a
                st.usedVendor = st.usedVendor + v
            end
        end
        -- For choosing recipes, stock that later steps still need isn't free: using it now
        -- means replacing it later. Only surplus stock costs nothing.
        if fromStock > 1e-9 and self.demand then
            local surplus = math.max(0, (st.stock - stockBefore) - self:FutureNeed(item, s))
            local needed = math.max(0, fromStock - surplus)
            if needed > 0 then
                local repl = self:UnitCost(item, s, depth)
                if repl < INF then cost = cost + needed * repl end
            end
        end
        return cost
    end

    if probeMark then self:RevertUsage(probeMark) end

    st.usedStock = st.usedStock + fromStock
    st.usedBags = st.usedBags + fromBags
    if self.makers[item] then
        -- remember when craftable items are consumed, to value earlier crafts of them
        self.consumed[item] = self.consumed[item] or {}
        addTo(self.consumed[item], s, qty)
    end

    local r
    if depth == 0 and self.sink then
        r = self.sink[item] or { qty = 0, cost = 0, stock = 0, bags = 0, ah = 0, vendor = 0, craft = 0,
            ahPrice = st.ah, vendorPrice = st.vendor, seed = st.seed }
        self.sink[item] = r
        r.qty, r.cost = r.qty + qty, r.cost + cost
        r.stock, r.bags = r.stock + fromStock, r.bags + fromBags
    end

    if rest > 1e-9 then
        if buyCost <= craftCost then
            st.usedAH, st.usedVendor = st.usedAH + a, st.usedVendor + v
            if r then r.ah, r.vendor = r.ah + a, r.vendor + v end
        else
            local crafts = rest / yieldOf(self.prof, maker)
            local rg = maker.rg
            local spentBefore = self.prepSpent or 0
            for j = 1, #rg, 2 do
                local rc = self:ReagentCost(rg[j], rg[j + 1] * crafts, s, depth + 1, true)
                if rc == INF then return INF end
            end
            -- this craft's own materials cost (nested extra crafts are recorded separately)
            local own = craftCost - ((self.prepSpent or 0) - spentBefore)
            self.prepSpent = (self.prepSpent or 0) + own
            if self.prepInfo then
                local pi = self.prepInfo[item] or { qty = 0, crafts = 0, cost = 0, rec = maker }
                pi.qty, pi.crafts, pi.cost = pi.qty + rest, pi.crafts + crafts, pi.cost + own
                self.prepInfo[item] = pi
            end
            addTo(self.prep, item, rest)
            if self.prepBatches then
                table.insert(self.prepBatches, { rec = maker, crafts = crafts, item = item })
            end
            addTo(self.prepTotal, item, rest)
            self.prepRec[item] = maker
            if r then r.craft = r.craft + rest end
        end
    end
    return cost
end

-- Units of item that steps after skill s will consume (from the previous iteration).
function Ctx:FutureNeed(item, s)
    local d = self.demand and self.demand[item]
    return d and d[s + 1] or 0
end

-- Expected cost of one skill point with rec at skill s.
-- Returns the selection cost (output needed later valued at replacement cost, the rest at
-- sale value), then crafts, materials cost and units made.
function Ctx:PointCost(rec, s, commit)
    local ch = Planner.Chance(rec, s)
    if ch <= 0 then return INF end
    local crafts = 1 / ch
    local mark
    if not commit then mark = self.undoTop end
    local c = 0
    local rg = rec.rg
    for j = 1, #rg, 2 do
        c = c + self:ReagentCost(rg[j], rg[j + 1] * crafts, s, 0, commit)
        if c == INF then
            if mark then self:RevertUsage(mark) end
            return INF
        end
    end
    local made, credit = 0, 0
    if rec.i then
        made = crafts * yieldOf(self.prof, rec)
        local st = self:Supply(rec.i)
        local saleU = self:SaleOf(rec.i)
        local keep = 0
        if self.demand then
            local inStock = st.stock - st.usedStock
            keep = math.max(0, math.min(made, self:FutureNeed(rec.i, s) - inStock))
        end
        local repl = saleU
        if keep > 0 then
            repl = self:UnitCost(rec.i, s, 0)
            if repl == INF or repl < saleU then repl = saleU end
        end
        credit = keep * repl + (made - keep) * saleU
        if commit then st.stock = st.stock + made end
    end
    if mark then self:RevertUsage(mark) end
    return c - credit, crafts, c, made
end

-- Materials cost of a single craft of rec at skill s (a required tool). Nothing made goes to stock.
function Ctx:OneCraft(rec, s, commit)
    local mark
    if not commit then mark = self.undoTop end
    local c = 0
    local rg = rec.rg
    for j = 1, #rg, 2 do
        c = c + self:ReagentCost(rg[j], rg[j + 1], s, 0, commit)
        if c == INF then
            if mark then self:RevertUsage(mark) end
            return INF
        end
    end
    if mark then self:RevertUsage(mark) end
    return c
end

-- Required tools (Data/RequiredTools.lua) that fall inside this plan, sorted by when they're due.
local function requiredTools(ctx, prof, startSkill, target, recipes)
    local defs = ns.Data.requiredTools and ns.Data.requiredTools[prof]
    local out = {}
    for _, def in ipairs(defs or {}) do
        if def.at < target and (not def.minTarget or target >= def.minTarget) then
            local rec
            for _, r in ipairs(recipes) do
                if r.i == def.item then rec = r break end
            end
            if rec then
                local at = math.max(def.at, ctx.learn[rec])
                out[#out + 1] = {
                    def = def, rec = rec, item = def.item, boe = def.boe,
                    at = at, maxAt = def.maxAt, by = math.max(def.by or at, at),
                    have = ns.Prices.Owned(def.item) > 0,
                }
            end
        end
    end
    table.sort(out, function(a, b) return a.at < b.at end)
    return out
end

---------------------------------------------------------------------------
-- Build
---------------------------------------------------------------------------
-- planned: optional set of recipe keys the player intends to obtain (treated as free).
function Planner.Build(prof, startSkill, target, planned)
    local recipes = ns.Data.recipes[prof]
    if not recipes then return nil, "unknown profession " .. tostring(prof) end
    target = math.min(target or ns.MAX_SKILL, ns.MAX_SKILL)
    startSkill = math.max(1, startSkill or 1)

    local known = ns.cdb.known[prof] or {}
    local ctx = setmetatable({
        prof = prof, supply = {}, makers = {}, allowed = {}, learn = {}, learnExact = {},
        sale = {}, saleSrc = {}, itemSale = {}, itemSaleSrc = {}, itemSaleInfo = {}, acq = {}, acqHow = {},
        undo = {}, undoTop = 0,
    }, Ctx)

    local candidates = {}
    for _, rec in ipairs(recipes) do
        local learn, exact = Planner.LearnLevel(prof, rec)
        ctx.learn[rec], ctx.learnExact[rec] = learn, exact
        ctx.sale[rec], ctx.saleSrc[rec] = 0, "none"
        if rec.i then ctx.sale[rec], ctx.saleSrc[rec] = ctx:SaleOf(rec.i) end
        local cost, how = Planner.Acquisition(prof, rec, known, planned)
        -- Recipes with a cooldown (Mooncloth, transmutes...) can't be repeated for levelling.
        if rec.cd then cost, how = nil, "cooldown" end
        ctx.acq[rec], ctx.acqHow[rec] = cost, how
        if rec.i then
            ctx.makers[rec.i] = ctx.makers[rec.i] or {}
            table.insert(ctx.makers[rec.i], rec)
        end
        -- only recipes that can give a skill-up somewhere in the range
        if rec.k[4] > startSkill and learn < target then
            table.insert(candidates, rec)
        end
        if cost == 0 then ctx.allowed[rec] = true end
    end

    -- Required tools: their recipe is needed whatever the options say (e.g. "buy recipes" off),
    -- so price a pattern directly when the usual rules excluded it.
    local tools = requiredTools(ctx, prof, startSkill, target, recipes)
    for _, t in ipairs(tools) do
        local rec = t.rec
        if not t.have then
            if ctx.acq[rec] == nil and rec.book and ctx.acqHow[rec] ~= "cooldown" then
                local ah = ns.Prices.AH(rec.book)
                local v = ns.Prices.Vendor(rec.book)
                if v and (not ah or v <= ah) then ctx.acq[rec], ctx.acqHow[rec] = v, "vendor"
                elseif ah then ctx.acq[rec], ctx.acqHow[rec] = ah, "AH"
                else ctx.acqHow[rec] = "unpriced" end
            end
            -- A tool you have to craft means getting its recipe anyway, so levelling may use it too
            -- (only when the recipe is actually priced/obtainable).
            if not t.boe and ctx.acq[rec] then ctx.allowed[rec] = true end
        end
    end

    -- With avoidGreen, a green craft (skill at or above its green threshold) is judged as if
    -- its output were worth nothing. So it is only used when it beats every orange/yellow
    -- option on materials alone, never because its output sells well.
    local avoidGreen = ns.db.opts.avoidGreen
    local function isGreen(rec, s)
        return s >= rec.k[3]
    end

    -- Unlimited-supply cost per skill point for a recipe over the range.
    local function costCurve(rec)
        local curve = {}
        local from = math.max(startSkill, ctx.learn[rec])
        local to = math.min(target - 1, rec.k[4] - 1)
        for s = from, to do
            local ch = Planner.Chance(rec, s)
            if ch > 0 then
                local c = ctx:CraftCost(rec, s)
                if c < INF then
                    if avoidGreen and isGreen(rec, s) then c = c + ctx.sale[rec] * yieldOf(prof, rec) end
                    curve[s] = c / ch
                end
            end
        end
        return curve
    end

    -- Pass 1: free recipes give the baseline; add paid recipes while they save more than they cost.
    local best = {}
    for s = startSkill, target - 1 do best[s] = INF end
    local curves = {}
    for _, rec in ipairs(candidates) do
        if ctx.allowed[rec] then
            curves[rec] = costCurve(rec)
            for s, c in pairs(curves[rec]) do
                if c < best[s] then best[s] = c end
            end
        end
    end

    local BIG = 1e9 -- value of covering a skill point that nothing else covers
    local function savings(curve)
        local total = 0
        for s, c in pairs(curve) do
            if best[s] == INF then total = total + BIG
            elseif c < best[s] then total = total + (best[s] - c) end
        end
        return total
    end

    local paid, unpriced = {}, {}
    for _, rec in ipairs(candidates) do
        if not ctx.allowed[rec] then
            if ctx.acq[rec] then
                curves[rec] = costCurve(rec)
                table.insert(paid, rec)
            elseif ctx.acqHow[rec] == "unpriced" or ctx.acqHow[rec] == "special" or ctx.acqHow[rec] == "spec" then
                table.insert(unpriced, rec)
            end
        end
    end

    while true do
        local pick, pickGain
        for _, rec in ipairs(paid) do
            if not ctx.allowed[rec] then
                local gain = savings(curves[rec]) - ctx.acq[rec]
                if gain > 0 and (not pickGain or gain > pickGain) then pick, pickGain = rec, gain end
            end
        end
        if not pick then break end
        ctx.allowed[pick] = true
        for s, c in pairs(curves[pick]) do
            if c < best[s] then best[s] = c end
        end
    end

    -- Tools with a craft window (e.g. orange range) are placed at the costliest skill point
    -- in that window, so the guaranteed skill-up replaces the most expensive normal point.
    for _, t in ipairs(tools) do
        if t.maxAt and not t.have then
            local lo = math.max(t.at, startSkill)
            local hi = math.min(t.maxAt, target - 1)
            if lo <= hi then
                local pickS, pickCost = lo, best[lo]
                for s = lo + 1, hi do
                    if best[s] > pickCost then pickS, pickCost = s, best[s] end
                end
                t.at = pickS
                t.by = math.max(t.by, t.at)
            end
        end
    end
    table.sort(tools, function(a, b) return a.at < b.at end)

    -- Unpriced patterns that would have helped, if you can find them.
    local missed = {}
    for _, rec in ipairs(unpriced) do
        local gain = savings(costCurve(rec))
        if gain > 0 then table.insert(missed, { rec = rec, gain = gain }) end
    end
    table.sort(missed, function(a, b) return a.gain > b.gain end)

    -- Pass 2: allocate skill points.
    local usable = {}
    for _, rec in ipairs(candidates) do
        if ctx.allowed[rec] then table.insert(usable, rec) end
    end

    local thinRatio = ns.db.opts.thinRatio

    local function allocate(demand)
        for _, st in pairs(ctx.supply) do resetUsage(st) end
        ctx.undoTop = 0
        ctx.demand, ctx.consumed = demand, {}
        ctx.prepTotal, ctx.prepRec = {}, {}

        local steps, gaps, used, madeTotal = {}, {}, {}, {}
        local toolsOut = {}
        local cur
        -- Skill is tracked as an expected (fractional) value: each step gives one point, and
        -- crafts made just before it ("prep") add their own expected skill-ups.
        local skill = startSkill

        -- Cheapest usable recipe for a skill point at s (selection cost).
        local function bestAt(s)
            local pick, pickCost
            for _, rec in ipairs(usable) do
                if ctx.learn[rec] <= s and rec.k[4] > s then
                    local c, _, mats = ctx:PointCost(rec, s, false)
                    if c < INF and avoidGreen and isGreen(rec, s) then c = mats end
                    if c < INF and (not pickCost or c < pickCost) then pick, pickCost = rec, c end
                end
            end
            return pick, pickCost
        end

        -- Commits one step: `run` spends the materials and returns crafts, materials cost and
        -- units made. A normal step gives one skill point; a tool craft gives its chance.
        local function record(pick, s, run, tool)
            local green = isGreen(pick, s)
            ctx.sink, ctx.prep, ctx.prepBatches, ctx.prepInfo = {}, {}, {}, {}
            local crafts, matsCost, made = run()
            local sink, prep, batches, prepInfo = ctx.sink, ctx.prep, ctx.prepBatches, ctx.prepInfo
            ctx.prepInfo = nil
            ctx.sink, ctx.prep, ctx.prepBatches = nil, nil, nil
            if not crafts or matsCost == INF then return false end

            -- Prep crafts happen first, at the current skill, and may give skill-ups.
            local prepGain = {}
            local x = skill
            for _, b in ipairs(batches) do
                local g, left = 0, b.crafts
                while left > 1e-9 do
                    local w = math.min(1, left)
                    local ch = Planner.Chance(b.rec, math.floor(x + g))
                    if ch <= 0 then break end
                    g = g + w * ch
                    left = left - w
                end
                if g > 0 then
                    addTo(prepGain, b.item, g)
                    x = x + g
                end
            end
            local newSkill, newTo
            if tool then
                newSkill = math.min(target, x + Planner.Chance(pick, math.floor(x)))
                newTo = math.max(s, math.floor(newSkill))
            else
                newSkill = math.min(target, x + 1)
                newTo = math.max(s + 1, math.floor(newSkill))
            end
            used[pick] = true
            if pick.i and made > 0 then addTo(madeTotal, pick.i, made) end
            if tool or not (cur and cur.rec == pick and cur.to == s and not cur.tool) then
                cur = {
                    from = s, to = newTo, rec = pick, crafts = 0, reagents = 0, made = 0, tool = tool,
                    mats = {}, prep = {}, prepGain = {}, prepInfo = {}, chanceFrom = Planner.Chance(pick, s),
                }
                table.insert(steps, cur)
            else
                cur.to = newTo
            end
            for item, g in pairs(prepGain) do addTo(cur.prepGain, item, g) end
            skill = newSkill
            cur.chanceTo = Planner.Chance(pick, s)
            if green and not tool then cur.green = true end
            for item, r in pairs(sink) do
                local m = cur.mats[item]
                if not m then
                    cur.mats[item] = r
                else
                    for _, k in ipairs({ "qty", "cost", "stock", "bags", "ah", "vendor", "craft" }) do
                        m[k] = m[k] + r[k]
                    end
                end
            end
            for item, q in pairs(prep) do addTo(cur.prep, item, q) end
            for item, pi in pairs(prepInfo) do
                local c = cur.prepInfo[item] or { qty = 0, crafts = 0, cost = 0, rec = pi.rec }
                c.qty, c.crafts, c.cost = c.qty + pi.qty, c.crafts + pi.crafts, c.cost + pi.cost
                cur.prepInfo[item] = c
            end
            cur.crafts = cur.crafts + crafts
            cur.reagents = cur.reagents + matsCost
            cur.made = cur.made + made
            return true
        end

        -- A required tool: already owned, bought (if it can be and that's cheaper), or crafted.
        local function doTool(t, s)
            local out = { item = t.item, rec = t.rec, at = s, by = t.by, boe = t.boe,
                how = ctx.acqHow[t.rec], acqCost = ctx.acq[t.rec] }
            toolsOut[#toolsOut + 1] = out
            if t.have then
                out.action = "have"
                return
            end
            if t.boe then
                local st = ctx:Supply(t.item)
                local buyCost, a, v = buySplit(st, 1)
                local mats = ctx:OneCraft(t.rec, s, false)
                -- Crafting also gives a skill-up (worth what the point would cost otherwise),
                -- and may need the recipe first.
                local _, pointCost = bestAt(s)
                local craftNet = mats + (ctx.acq[t.rec] or 0)
                    - Planner.Chance(t.rec, s) * math.max(0, pointCost or 0)
                out.buyCost, out.craftNet = buyCost < INF and buyCost or nil, craftNet
                if buyCost < INF and (mats == INF or buyCost <= craftNet) then
                    st.usedAH, st.usedVendor = st.usedAH + a, st.usedVendor + v
                    out.action, out.cost = "buy", buyCost
                    return
                end
            end
            if not ctx.acq[t.rec] and ctx.acqHow[t.rec] ~= "unpriced" then
                -- e.g. needs a specialization: can't plan the craft
                out.action = "blocked"
                return
            end
            if ctx:OneCraft(t.rec, s, false) == INF then
                out.action = "nomats" -- a material has no AH or vendor price
                return
            end
            if record(t.rec, s, function()
                local c = ctx:OneCraft(t.rec, s, true)
                if c == INF then return nil, INF, 0 end
                out.cost = c
                return 1, c, 0
            end, true) then
                out.action = "craft"
            else
                out.action = "nomats"
            end
            cur = nil
        end

        local nextTool = 1
        while skill < target do
            local s = math.floor(skill)
            local t = tools[nextTool]
            if t and s >= t.at then
                nextTool = nextTool + 1
                doTool(t, s)
            else
                local pick = bestAt(s)
                if not pick then
                    table.insert(gaps, s)
                    cur = nil
                    skill = s + 1
                else
                    if not record(pick, s, function()
                        local _, crafts, matsCost, made = ctx:PointCost(pick, s, true)
                        return crafts, matsCost, made
                    end) then
                        table.insert(gaps, s)
                        cur = nil
                        skill = s + 1
                    end
                end
            end
        end

        -- How many of each step's crafts later steps use (oldest crafts used first).
        local usedLeft = {}
        for item in pairs(madeTotal) do
            local st = ctx.supply[item]
            usedLeft[item] = st and st.usedStock or 0
        end
        for _, st in ipairs(steps) do
            local item = st.rec.i
            if item and usedLeft[item] and usedLeft[item] > 1e-6 then
                st.keep = math.min(st.made, usedLeft[item])
                usedLeft[item] = usedLeft[item] - st.keep
            end
        end

        -- Recipes to acquire that this plan actually uses (steps and prep crafts).
        local acquire, seen = {}, {}
        local function addAcq(rec)
            if seen[rec] or ctx.acqHow[rec] == "known" or ctx.acqHow[rec] == "auto" then return end
            seen[rec] = true
            table.insert(acquire, {
                rec = rec, cost = ctx.acq[rec], how = ctx.acqHow[rec],
                learn = ctx.learn[rec], exact = ctx.learnExact[rec],
            })
        end
        for _, rec in ipairs(candidates) do
            if used[rec] then addAcq(rec) end
        end
        for _, t in ipairs(tools) do
            if used[t.rec] then addAcq(t.rec) end
        end
        for _, rec in pairs(ctx.prepRec) do addAcq(rec) end
        table.sort(acquire, function(a, b) return a.learn < b.learn end)

        -- Shopping list.
        local shopping = {}
        local totals = { ah = 0, vendor = 0, recipes = 0, sale = 0 }
        for item, st in pairs(ctx.supply) do
            local need = st.usedBags + st.usedAH + st.usedVendor
            if need > 1e-6 then
                local row = {
                    item = item,
                    bags = st.usedBags,
                    ah = math.ceil(st.usedAH - 1e-6),
                    vendor = math.ceil(st.usedVendor - 1e-6),
                    ahPrice = st.ah, vendorPrice = st.vendor, seed = st.seed,
                    ahQty = st.qtyKnown and st.ahQty or nil, age = st.age,
                }
                row.ahCost = row.ah * (st.ah or 0)
                row.vendorCost = row.vendor * (st.vendor or 0)
                row.thin = row.ah > 0 and (not st.qtyKnown or row.ah > st.ahQty * thinRatio)
                row.stale = row.ah > 0 and st.age and st.age >= 1
                totals.ah = totals.ah + row.ahCost
                totals.vendor = totals.vendor + row.vendorCost
                if row.bags > 1e-6 or row.ah > 0 or row.vendor > 0 then table.insert(shopping, row) end
            end
        end
        table.sort(shopping, function(a, b)
            if a.thin ~= b.thin then return a.thin end
            return (a.ahCost + a.vendorCost) > (b.ahCost + b.vendorCost)
        end)
        for _, a in ipairs(acquire) do totals.recipes = totals.recipes + (a.cost or 0) end

        -- Crafted items: how many were used by later steps, and the leftovers that get sold.
        local sales, crafted = {}, {}
        for item, made in pairs(madeTotal) do
            local st = ctx.supply[item]
            local usedLater = st and st.usedStock or 0
            local left = made - usedLater
            if left > 1e-6 then
                local unit, src = ctx:SaleOf(item)
                if unit > 0 then
                    table.insert(sales, { item = item, count = left, unit = unit, value = left * unit, src = src })
                    totals.sale = totals.sale + left * unit
                end
            end
            if usedLater > 1e-6 then
                crafted[item] = { item = item, inSteps = made, usedLater = usedLater, prep = 0 }
            end
        end
        for item, q in pairs(ctx.prepTotal) do
            local c = crafted[item] or { item = item, inSteps = madeTotal[item] or 0, usedLater = 0, prep = 0 }
            c.prep = q
            crafted[item] = c
        end
        local craftedList = {}
        for _, c in pairs(crafted) do craftedList[#craftedList + 1] = c end
        table.sort(craftedList, function(a, b) return (a.inSteps + a.prep) > (b.inSteps + b.prep) end)
        table.sort(sales, function(a, b) return a.value > b.value end)
        totals.net = totals.ah + totals.vendor + totals.recipes - totals.sale

        local estimated = 0
        for _, a in ipairs(acquire) do if not a.exact then estimated = estimated + 1 end end

        return {
            steps = steps, gaps = gaps, acquire = acquire, tools = toolsOut, shopping = shopping,
            sales = sales, crafted = craftedList, saleInfo = ctx.itemSaleInfo, totals = totals, estimatedLearn = estimated,
            consumed = ctx.consumed,
        }
    end

    -- Turn consumption by skill into "units needed after skill s" lookups.
    local function toDemand(consumed)
        local demand = {}
        for item, bySkill in pairs(consumed) do
            local d, acc = {}, 0
            for s = target, startSkill, -1 do
                acc = acc + (bySkill[s] or 0)
                d[s] = acc
            end
            demand[item] = d
        end
        return demand
    end

    local plan, demand
    for _ = 1, ITERATIONS do
        local run = allocate(demand)
        if not plan or #run.gaps < #plan.gaps
            or (#run.gaps == #plan.gaps and run.totals.net < plan.totals.net - 1) then
            plan = run
        end
        demand = toDemand(run.consumed)
    end

    local knownCount = 0
    for _ in pairs(known) do knownCount = knownCount + 1 end
    plan.prof, plan.start, plan.target = prof, startSkill, target
    plan.missed = missed
    plan.knownCount = knownCount
    plan.consumed = nil
    return plan
end
