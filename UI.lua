-- UI.lua: the planner window. Each line is a row; hover a step for the details behind its numbers.
local _, ns = ...

local UI = {}
ns.UI = UI

local Money = function(c) return ns.Prices.Money(c) end
local Name = function(id) return ns.Prices.ItemName(id) end

-- Tailwind 400-shades on the neutral theme; MUT (orange) is used for table headers.
local RED, YEL, GRY, GRN, ORA, BLU, WHT = "|cfff87171", "|cfffbbf24", "|cffa1a1a1", "|cff4ade80", "|cfffb923c", "|cff60a5fa", "|cfffafafa"
local MUT = ns.Skin.Hex(ns.Skin.HIGHLIGHT)
local R = "|r"
local Skin = ns.Skin

local RANK_CAPS = { 75, 150, 225 }

local function cnt(x)
    return tostring(math.ceil(x - 1e-6))
end

local function pct(x)
    return string.format("%d%%", math.floor(x * 100 + 0.5))
end


-- Tooltip for one step: every number behind its cost.
local function stepTip(st)
    return function(tt)
        tt:AddLine(("%s  (%d-%d)"):format(st.rec.n, st.from, st.to))
        tt:AddLine(("Chance to skill up: %s at %d, %s at %d"):format(pct(st.chanceFrom), st.from, pct(st.chanceTo), st.to - 1), 1, 1, 1)
        tt:AddLine(("Thresholds: yellow %d, green %d, grey %d"):format(st.rec.k[2], st.rec.k[3], st.rec.k[4]), 0.6, 0.6, 0.6)
        tt:AddLine(("Expected crafts: %s for %d skill points"):format(cnt(st.crafts), st.to - st.from), 1, 1, 1)
        tt:AddLine(" ")
        tt:AddLine("Materials", 1, 0.82, 0)
        local items = {}
        for item, m in pairs(st.mats) do items[#items + 1] = { item = item, m = m } end
        table.sort(items, function(a, b) return a.m.cost > b.m.cost end)
        for _, x in ipairs(items) do
            local m = x.m
            local parts = {}
            if m.stock > 1e-6 then parts[#parts + 1] = cnt(m.stock) .. " from earlier steps (free)" end
            if m.bags > 1e-6 then parts[#parts + 1] = cnt(m.bags) .. " bags (free)" end
            if m.ah > 1e-6 then
                local p = m.ahPrice
                parts[#parts + 1] = ("%s AH @ %s"):format(cnt(m.ah), p and Money(p) or "?")
            end
            if m.vendor > 1e-6 then
                local p, seed = m.vendorPrice, m.seed
                parts[#parts + 1] = ("%s vendor @ %s%s"):format(cnt(m.vendor), seed and "~" or "", p and Money(p) or "?")
            end
            if m.craft > 1e-6 then parts[#parts + 1] = cnt(m.craft) .. " crafted just before" end
            tt:AddDoubleLine(("%s x%s: %s"):format(Name(x.item), cnt(m.qty), table.concat(parts, ", ")), Money(m.cost), 1, 1, 1, 1, 1, 1)
        end
        tt:AddDoubleLine("Materials total", Money(st.reagents), 1, 0.82, 0, 1, 1, 1)
        tt:AddLine(" ")
        if st.rec.i then
            tt:AddLine(("Makes %s x %s. Later steps use them first; any left over are sold (see Sales)."):format(
                cnt(st.made), st.rec.n), 0.6, 0.6, 0.6, true)
        else
            tt:AddLine("Makes nothing to keep or sell (enchant).", 0.6, 0.6, 0.6)
        end
    end
end

-- Returns a list of { text = string, tip = function(tooltip) or nil }.
local MAX_LOOK_FOR = 12
local ROW_W = 590 -- width the table columns are designed for; they stretch with the window
-- Narrowest the window may get: the controls need MIN_W; the plan's tables need about
-- CONTENT_MIN design pixels at the current zoom (so zooming out allows a narrower window).
local MIN_W, MIN_H, CONTENT_MIN = 380, 360, 500
local function minWidth(zoom) return math.max(MIN_W, math.ceil(CONTENT_MIN * zoom) + 42) end

local function render(plan)
    local L = {}
    local function add(s, tip, check) L[#L + 1] = { text = s or "", tip = tip, check = check } end
    -- heading(text, "title") is the page title; heading(text, nil, over, sub) starts a card,
    -- with a small overline above the title and a muted description below it.
    local function heading(s, kind, over, sub) L[#L + 1] = { text = s, heading = kind or true, over = over, sub = sub } end
    local function strong(s) L[#L + 1] = { text = s, strong = true } end
    -- cols: { text, x, width, justify, wrap }. grid = true draws cell borders ("top" also the top edge).
    local function addCols(cols, tip, grid) L[#L + 1] = { text = "", cols = cols, tip = tip, grid = grid } end
    local t = plan.totals
    local base = plan.baseline or plan
    local planned = ns.Planned(plan.prof)

    -- Recipes to look for: from the plan without your picks, plus anything you picked.
    local lookFor, listed = {}, {}
    for i = 1, math.min(MAX_LOOK_FOR, #base.missed) do
        local m = base.missed[i]
        lookFor[#lookFor + 1] = m
        listed[ns.RecipeKey(m.rec)] = true
    end
    for _, rec in ipairs(ns.Data.recipes[plan.prof]) do
        local key = ns.RecipeKey(rec)
        if planned[key] and not listed[key] then
            listed[key] = true
            local gain
            for _, m in ipairs(base.missed) do if m.rec == rec then gain = m.gain end end
            lookFor[#lookFor + 1] = { rec = rec, gain = gain }
        end
    end
    local usedPlanned = {}
    for _, a in ipairs(plan.acquire) do
        if a.how == "planned" then usedPlanned[a.rec] = true end
    end
    -- What each unticked recipe would still save on top of the ticked ones.
    local gainNow = {}
    if plan.baseline then
        for _, m in ipairs(plan.missed) do gainNow[m.rec] = m.gain end
    end

    heading(("%s%s|r  %s%d -> %d|r"):format(WHT, ns.PROF_NAMES[plan.prof], GRY, plan.start, plan.target), "title")
    heading("Scan the auction house", nil, "STEP 1", "Run a full scan with Auctionator, then press Re-plan in the top right.")
    add(("Using your latest scan, it will cost about %s%s|r to level."):format(WHT, Money(base.totals.net)))
    add()
    heading("Optional recipes", nil, "STEP 2")
    if #lookFor == 0 then
        add(GRY .. "None: no recipe missing from the AH would save you money on this plan." .. R)
    else
        add(GRY .. "These recipes aren't listed on the AH, but will save you some money if you obtain them. The gold amount next to the recipe is the approximate amount you would save if you got the recipe for free." .. R)
        add()
        add(GRY .. "Look these up on wowhead and decide if it's worth traveling to a vendor or farming a drop. Tick off the ones you plan to obtain to update the plan." .. R)
        add()
        for _, m in ipairs(lookFor) do
            local key = ns.RecipeKey(m.rec)
            local gain = not m.gain and "" or (m.gain >= 1e9 and "fills a gap" or ("saves ~" .. Money(m.gain)))
            local rep = m.rec.rep and (GRY .. " (" .. m.rec.rep .. ")" .. R) or ""
            local unused = ""
            if planned[key] then
                if not usedPlanned[m.rec] then unused = RED .. " - not used by the plan" .. R end
            elseif plan.baseline then
                local now = gainNow[m.rec]
                if not now then
                    unused = RED .. " - no longer needed with your ticked recipes" .. R
                elseif m.gain and m.gain < 1e9 and now < 1e9 and math.abs(now - m.gain) > 0.1 * m.gain then
                    unused = ORA .. " - now saves ~" .. Money(now) .. " with your ticked recipes" .. R
                end
            end
            local learn = m.rec.req or m.rec.k[1]
            local spec = ns.Planner.ShippedSpec(plan.prof, m.rec)
            local title
            if spec then
                title = m.rec.n .. GRY .. " (trainer, needs " .. spec .. "; tick it if you are one)" .. R
                learn = ns.Planner.LearnLevel(plan.prof, m.rec)
            elseif m.rec.book then
                title = Name(m.rec.book)
            else
                title = m.rec.n .. GRY .. " (not taught by trainers: quest or other)" .. R
            end
            add(("%s - %s%s  %slearn at %s%s%s"):format(title, gain, rep, GRY, tostring(learn or "?"), R, unused), nil, {
                checked = planned[key] and true or false,
                onClick = function(checked)
                    planned[key] = checked or nil
                    UI.Replan()
                end,
            })
        end
    end
    add()
    local nPlanned = 0
    for _ in pairs(usedPlanned) do nPlanned = nPlanned + 1 end
    local saved = nPlanned > 0 and (GRN .. ("  (saves %s)"):format(Money(base.totals.net - t.net)) .. R) or ""
    heading("Shopping list", nil, "STEP 3")
    add(("Updated cost using optional recipes: %s%s|r%s"):format(WHT, Money(t.net), saved))
    add()
    -- Statement-style breakdown: costs negative, sales positive, amounts right-aligned.
    local function signed(v)
        if v > 0.5 then return "+" .. Money(v) end
        if v < -0.5 then return Money(v) end
        return Money(0)
    end
    local function stmt(label, v, color)
        addCols({ { (color or "") .. label .. R, 0, 70, "LEFT" }, { (color or "") .. signed(v) .. R, 70, 110, "RIGHT" } })
        L[#L].fixed = true
    end
    stmt("AH:", -t.ah)
    stmt("Vendor:", -t.vendor)
    stmt("Recipes:", -t.recipes)
    stmt("Sales:", t.sale)
    stmt("Net:", -t.net, WHT)
    if nPlanned > 0 then
        add(GRY .. "Steps using a ticked recipe are marked " .. BLU .. "*" .. GRY .. ". Have the recipe by its step." .. R)
    end

    if plan.knownCount == 0 and ns.CharSkill(plan.prof) then
        add(ORA .. "Open your " .. ns.PROF_NAMES[plan.prof] .. " window once so known recipes count as free." .. R)
    end
    if plan.estimatedLearn > 0 then
        add(ORA .. plan.estimatedLearn .. " trainer recipe(s) marked ~ in Step 4 have estimated learn levels. Open the trainer to make them exact." .. R)
    end
    if #plan.gaps > 0 then
        add(RED .. ("No usable recipe for %d skill point(s), first at %d (missing prices or recipes)."):format(#plan.gaps, plan.gaps[1]) .. R)
    end
    add()

    local purchase = {}
    for _, a in ipairs(plan.acquire) do
        if a.how == "AH" or a.how == "vendor" then purchase[#purchase + 1] = a end
    end
    if #purchase > 0 then
        strong("Recipes")
        add(GRY .. "Prices are current AH price. Check wowhead for vendor price/location and feel free to travel to the vendor if it's worth the cost savings." .. R)
        add()
        local R1, R2, R3 = 0, 62, 412
        local RW1, RW2, RW3 = 62, 350, 178
        addCols({
            { MUT .. "Skill" .. R, R1, RW1, "LEFT" }, { MUT .. "Recipe" .. R, R2, RW2, "LEFT" },
            { MUT .. "Price" .. R, R3, RW3, "RIGHT" },
        }, nil, "top")
        for _, a in ipairs(purchase) do
            local note = a.how == "vendor" and (GRY .. " (vendor price you've seen)" .. R) or ""
            addCols({
                { tostring(a.learn), R1, RW1, "LEFT" }, { Name(a.rec.book), R2, RW2, "LEFT", true },
                { Money(a.cost) .. note, R3, RW3, "RIGHT", true },
            }, nil, true)
            L[#L].item = a.rec.book
        end
        add()
    end

    strong("Materials")
    add(GRY .. "If the total cost you see on the AH is much different than this table, rescan the AH, then press Re-plan in the top right." .. R)
    add(GRY .. "Shift-click an item with the AH open to search for it." .. R)
    add()
    local C1, C2, C3, C4 = 0, 290, 380, 485
    local CW1, CW2, CW3, CW4 = 290, 90, 105, 105
    addCols({
        { MUT .. "Item" .. R, C1, CW1, "LEFT" }, { MUT .. "Quantity" .. R, C2, CW2, "RIGHT" },
        { MUT .. "Cost per Item" .. R, C3, CW3, "RIGHT" }, { MUT .. "Total Cost" .. R, C4, CW4, "RIGHT" },
    }, nil, "top")
    local grand, anyThin, anySeed, anyBags = 0, false, false, false
    for _, row in ipairs(plan.shopping) do
        local qty = row.ah + row.vendor
        local total = row.ahCost + row.vendorCost
        local bags = math.floor(row.bags + 1e-6)
        local name = Name(row.item)
        if row.thin then name = RED .. "! " .. R .. name; anyThin = true end
        if row.vendor > 0 and row.ah == 0 then name = name .. GRY .. " (vendor)" .. R end
        if bags > 0 then name = name .. GRN .. (" (+%d from bags)"):format(bags) .. R; anyBags = true end
        if row.stale then name = name .. RED .. (" price was %dd old when planned"):format(row.age) .. R end
        local unit
        if qty > 0 then
            unit = total / qty
        else
            unit = row.ahPrice or row.vendorPrice or 0
        end
        local seed = row.vendor > 0 and row.seed
        if seed then anySeed = true end
        grand = grand + total
        addCols({
            { name, C1, CW1, "LEFT", true }, { tostring(qty), C2, CW2, "RIGHT" },
            { (seed and "~" or "") .. Money(unit), C3, CW3, "RIGHT" }, { Money(total), C4, CW4, "RIGHT" },
        }, nil, true)
        L[#L].item = row.item
    end
    addCols({
        { WHT .. "Total" .. R, C1, CW1, "LEFT" }, { "", C2, CW2, "RIGHT" },
        { "", C3, CW3, "RIGHT" }, { WHT .. Money(grand) .. R, C4, CW4, "RIGHT" },
    }, nil, true)
    local notes = {}
    if anyThin then notes[#notes + 1] = "! = the plan needs much of what's listed; it may sell out, so buy these first" end
    if anySeed then notes[#notes + 1] = "~ = approximate vendor price" end
    if anyBags then notes[#notes + 1] = "items from your bags are free and not counted" end
    if #notes > 0 then add(GRY .. table.concat(notes, ". ") .. "." .. R) end
    add()

    heading("Craft", nil, "STEP 4", "Hover a step for its materials and prices.")
    local estimated = {}
    for _, a in ipairs(plan.acquire) do
        if not a.exact then estimated[a.rec] = true end
    end
    -- Cells are edge to edge (x, width) and drawn with borders.
    local S1, S2, S3, S4, S5 = 0, 62, 220, 272, 490
    local W1, W2, W3, W4, W5 = 62, 158, 52, 218, 100
    addCols({
        { MUT .. "Skill" .. R, S1, W1, "LEFT" }, { MUT .. "Craft" .. R, S2, W2, "LEFT" },
        { MUT .. "Crafts" .. R, S3, W3, "RIGHT" }, { MUT .. "Total Mats" .. R, S4, W4, "LEFT" },
        { MUT .. "Keep/Sell" .. R, S5, W5, "LEFT" },
    }, nil, "top")

    -- One "Light Leather (40)" line per material, for `crafts` crafts of rec.
    local function matsList(rec, crafts)
        local parts = {}
        local n = math.ceil(crafts - 1e-6) -- same craft count as the "# Crafts" column
        local rg = rec.rg
        for j = 1, #rg, 2 do
            parts[#parts + 1] = ("%s (%d)"):format(Name(rg[j]), rg[j + 1] * n)
        end
        return table.concat(parts, "\n")
    end

    -- Display rows. Extra crafts of an intermediate (made because a step needs more than
    -- earlier steps produced) are folded into the latest earlier step that makes the same
    -- item ("make them all then"), or else shown as their own row with no skill range.
    local rows = {}
    local lastMaker = {} -- item -> display row of the latest step crafting it
    for _, st in ipairs(plan.steps) do
        local row = {
            st = st, rec = st.rec, crafts = st.crafts, mats = st.reagents,
            made = st.made, keep = st.keep or 0, extraCrafts = 0, extraCost = 0,
        }
        local items = {}
        for item in pairs(st.prepInfo) do items[#items + 1] = item end
        table.sort(items, function(a, b) return st.prepInfo[a].qty > st.prepInfo[b].qty end)
        for _, item in ipairs(items) do
            local pi = st.prepInfo[item]
            row.mats = row.mats - pi.cost
            local maker = lastMaker[item]
            if maker then
                maker.crafts = maker.crafts + pi.crafts
                maker.mats = maker.mats + pi.cost
                maker.made = maker.made + pi.qty
                maker.keep = maker.keep + pi.qty
                maker.extraCrafts = maker.extraCrafts + pi.crafts
                maker.extraCost = maker.extraCost + pi.cost
            else
                local prepRow = {
                    prepOnly = true, rec = pi.rec, crafts = pi.crafts, mats = pi.cost,
                    made = pi.qty, keep = pi.qty, gain = st.prepGain[item] or 0,
                    extraCrafts = 0, extraCost = 0,
                }
                rows[#rows + 1] = prepRow
                lastMaker[item] = prepRow
            end
        end
        rows[#rows + 1] = row
        if st.rec.i then lastMaker[st.rec.i] = row end
    end

    local capIdx = 1
    while RANK_CAPS[capIdx] and RANK_CAPS[capIdx] <= plan.start do capIdx = capIdx + 1 end
    for _, row in ipairs(rows) do
        local st = row.st
        if st then
            while RANK_CAPS[capIdx] and st.to > RANK_CAPS[capIdx] do
                local td = ns.Data.trainerData and ns.Data.trainerData[plan.prof]
                local at = td and td.ranks[capIdx]
                local when = at and (" (learnable at " .. at .. ")") or ""
                addCols({ { ("%sTrain the next rank%s before %d%s"):format(BLU, when, RANK_CAPS[capIdx], R),
                    0, ROW_W, "CENTER", true } }, nil, true)
                capIdx = capIdx + 1
            end
        end

        local rec = row.rec
        local craft = (usedPlanned[rec] and (BLU .. "*" .. R) or "") .. (estimated[rec] and (ORA .. "~" .. R) or "")
            .. WHT .. rec.n .. R .. ((st and st.green) and (GRN .. " (green)" .. R) or "")

        local fate
        if not rec.i then
            fate = GRY .. "-" .. R
        else
            local si = plan.saleInfo and plan.saleInfo[rec.i]
            local sellTo = si and "sell on AH" or "vendor"
            if row.keep >= row.made - 0.5 then
                fate = ORA .. "Keep all" .. R
            elseif row.keep >= 0.5 then
                fate = ORA .. "Keep " .. cnt(row.keep) .. R .. ", " .. sellTo .. " rest"
            else
                fate = sellTo == "vendor" and "Vendor" or "Sell on AH"
            end
        end

        local tip
        if st then
            local base = stepTip(st)
            tip = function(tt)
                base(tt)
                if row.extraCrafts > 0.5 then
                    tt:AddLine(" ")
                    tt:AddLine(("Plus %s more crafts to keep for later steps (%s, no skill-ups counted)."):format(
                        cnt(row.extraCrafts), Money(row.extraCost)), 1, 0.5, 0.25, true)
                end
            end
        else
            tip = function(tt)
                tt:AddLine(rec.n)
                tt:AddLine(("Craft %s now; the next steps use them. %s"):format(cnt(row.crafts),
                    row.gain >= 0.5 and ("Expect about " .. math.floor(row.gain + 0.5) .. " skill-ups.") or "No skill-ups expected."),
                    1, 1, 1, true)
                tt:AddDoubleLine("Materials", Money(row.mats), 1, 0.82, 0, 1, 1, 1)
            end
        end

        addCols({
            { st and ("%d-%d"):format(st.from, st.to) or "-", S1, W1, "LEFT" }, { craft, S2, W2, "LEFT", true },
            { cnt(row.crafts), S3, W3, "RIGHT" }, { matsList(rec, row.crafts), S4, W4, "LEFT", true },
            { fate, S5, W5, "LEFT", true },
        }, tip, true)

    end
    add()

    if #plan.sales > 0 then
        strong(WHT .. "Sales" .. R .. GRY .. "  (crafted items not needed by later steps)" .. R)
        for _, r in ipairs(plan.sales) do
            add(("  %s x%s @ %s = %s  %s(%s)%s"):format(Name(r.item), cnt(r.count), Money(r.unit), Money(r.value),
                GRY, r.src == "ah" and "AH" or "vendor", R))
        end
        add()
    end

    return L
end
UI.Render = render

---------------------------------------------------------------------------
local frame, content, startBox, targetBox, scroll
local rows = {}
local state = { prof = nil, start = nil }

-- Target skill per profession, remembered across sessions.
local function getTarget(prof)
    local t = ns.db.targets[prof]
    if t and t > 1 and t <= ns.MAX_SKILL then return t end
    return ns.MAX_SKILL
end

local function setTarget(prof, t)
    if not prof then return end
    if t and t > 1 and t < ns.MAX_SKILL then
        ns.db.targets[prof] = math.floor(t)
    else
        ns.db.targets[prof] = nil
    end
end
local function getRow(i)
    local row = rows[i]
    if row then return row end
    row = CreateFrame("Button", nil, content)
    row.fs = Skin.FontString(row, Skin.Body())
    row.fs:SetJustifyH("LEFT")
    row.check = Skin.Check(row, 14)
    row.check:SetPoint("LEFT", 2, 0)
    row.check:SetScript("OnClick", function(self)
        if self.onClick then self.onClick(self:GetChecked() and true or false) end
    end)
    row.hl = row:CreateTexture(nil, "BACKGROUND")
    Skin.Color(row.hl, Skin.MUTED, 0.6)
    row.hl:Hide()
    row.over = Skin.FontString(row, Skin.Overline()) -- "STEP 1" above a card title
    row.over:SetJustifyH("LEFT")
    row.over:SetTextColor(Skin.HIGHLIGHT[1], Skin.HIGHLIGHT[2], Skin.HIGHLIGHT[3])
    row.sub = Skin.FontString(row, Skin.Body()) -- description under a card title
    row.sub:SetJustifyH("LEFT")
    row.sub:SetTextColor(Skin.DIM[1], Skin.DIM[2], Skin.DIM[3])
    row:SetScript("OnClick", function(self)
        if self.item and IsShiftKeyDown() then UI.SearchItem(self.item) end
    end)
    row:SetScript("OnEnter", function(self)
        if self.item and not self.tip then
            self.hl:Show()
            GameTooltip:SetOwner(self, "ANCHOR_CURSOR_RIGHT")
            if GameTooltip.SetItemByID then GameTooltip:SetItemByID(self.item) else GameTooltip:AddLine(Name(self.item)) end
            GameTooltip:AddLine("Shift-click to search the AH", 0.4, 0.8, 1)
            GameTooltip:Show()
            return
        end
        if not self.tip then return end
        self.hl:Show()
        GameTooltip:SetOwner(self, "ANCHOR_CURSOR_RIGHT")
        self.tip(GameTooltip)
        GameTooltip:Show()
    end)
    row:SetScript("OnLeave", function(self)
        self.hl:Hide()
        GameTooltip:Hide()
    end)
    rows[i] = row
    return row
end

local lastLines
-- Column positions are laid out for ROW_W; stretch them to the current width.
local function scaleCols(cols, k)
    if k == 1 then return cols end
    local out = {}
    for c, col in ipairs(cols) do
        local x1, x2 = math.floor(col[2] * k + 0.5), math.floor((col[2] + col[3]) * k + 0.5)
        out[c] = { col[1], x1, x2 - x1, col[4], col[5] }
    end
    return out
end

-- Rounded backgrounds drawn on the content frame (under the rows): one card per step and
-- one outlined box per table.
local CARD_PAD, CARD_GAP = 16, 14
local cardBoxes, tableBoxes = {}, {}
local function box(pool, i, fill, edge, r, sub)
    local b = pool[i]
    if not b then
        b = Skin.Box(content, fill, edge, r, "BACKGROUND", sub)
        pool[i] = b
    end
    b:Show()
    return b
end
local function place(b, x, y, w, h)
    b:ClearAllPoints()
    b:SetPoint("TOPLEFT", content, "TOPLEFT", x, -y)
    b:SetPoint("BOTTOMRIGHT", content, "TOPLEFT", x + w, -(y + h))
end

local function isBlank(line)
    return line and not line.cols and not line.check and not line.heading and (line.text or "") == ""
end

local function setLines(lines)
    lastLines = lines
    local y = 0
    local rowW = math.max(200, math.floor(content:GetWidth()))
    local nCards, nTables = 0, 0
    local cardTop, tableTop
    local function closeCard()
        if not cardTop then return end
        y = y + CARD_PAD
        nCards = nCards + 1
        place(box(cardBoxes, nCards, Skin.CARD, Skin.EDGE, 12, -8), 0, cardTop, rowW, y - cardTop)
        cardTop = nil
        y = y + CARD_GAP
    end
    for i, line0 in ipairs(lines) do
        local row = getRow(i)
        local card = line0.heading == true
        if card then
            closeCard()
            cardTop = y
            y = y + CARD_PAD
        end
        local x = cardTop and CARD_PAD or 0
        local rw = rowW - 2 * x
        local k = rw / ROW_W
        row:SetWidth(rw)
        local line = line0
        if line0.cols then
            line = setmetatable({ cols = scaleCols(line0.cols, line0.fixed and 1 or k) }, { __index = line0 })
        end
        local nextLine = lines[i + 1]
        local cardEnds = cardTop and (not nextLine or nextLine.heading == true)
        row.cols = row.cols or {}
        row.lines = row.lines or {}
        local colH = 0
        local PADX, PADY = line.grid and 10 or 0, line.grid and 7 or 0
        for c = 1, math.max(#row.cols, line.cols and #line.cols or 0) do
            local col = line.cols and line.cols[c]
            local fs = row.cols[c]
            if col then
                if not fs then
                    fs = Skin.FontString(row, Skin.Body())
                    row.cols[c] = fs
                end
                fs:ClearAllPoints()
                fs:SetPoint("TOPLEFT", col[2] + PADX, -PADY)
                fs:SetWidth(col[3] - 2 * PADX)
                fs:SetJustifyH(col[4])
                fs:SetWordWrap(col[5] and true or false)
                fs:SetFontObject(line.grid == "top" and Skin.Strong() or Skin.Body())
                fs:SetText(col[1])
                fs:Show()
                colH = math.max(colH, fs:GetStringHeight())
            elseif fs then
                fs:Hide()
            end
        end
        local indent = line.check and 24 or 0
        local overH = 0
        if card and line.over then
            row.over:ClearAllPoints()
            row.over:SetPoint("TOPLEFT", 0, 0)
            row.over:SetText(line.over)
            row.over:Show()
            overH = row.over:GetStringHeight() + 6
        else
            row.over:Hide()
        end
        local headTop = line.heading == "title" and 4 or overH
        row.fs:SetFontObject(line.heading == "title" and Skin.Title()
            or line.heading and Skin.Heading() or line.strong and Skin.Strong() or Skin.Body())
        row.fs:SetTextColor(Skin.FG[1], Skin.FG[2], Skin.FG[3])
        row.fs:ClearAllPoints()
        row.fs:SetPoint("TOPLEFT", indent, line.check and -4 or -headTop)
        row.fs:SetWidth(rw - indent)
        row.fs:SetText(line.text ~= "" and line.text or " ")
        local subH = 0
        if card and line.sub then
            row.sub:ClearAllPoints()
            row.sub:SetPoint("TOPLEFT", row.fs, "BOTTOMLEFT", 0, -6)
            row.sub:SetWidth(rw)
            row.sub:SetText(line.sub)
            row.sub:Show()
            subH = row.sub:GetStringHeight() + 6
        else
            row.sub:Hide()
        end
        row.tip = line.tip
        row.item = line.item
        if line.check then
            row.check:SetChecked(line.check.checked)
            row.check.onClick = line.check.onClick
            row.check:Show()
        else
            row.check.onClick = nil
            row.check:Hide()
        end
        local h
        if line.cols then
            row.fs:SetText("")
            h = math.max(12, colH) + 2 * PADY + (line.grid and 1 or 6)
        elseif line.heading == "title" then
            h = row.fs:GetStringHeight() + headTop + 12
        elseif line.heading then
            h = overH + row.fs:GetStringHeight() + subH + 14
        elseif isBlank(line) and cardEnds then
            h = 0 -- no trailing gap at the bottom of a card; the card has padding
        elseif isBlank(line) then
            h = 10
        else
            h = math.max(line.check and 22 or 14, row.fs:GetStringHeight() + (line.check and 8 or 2)) + 3
        end
        row:SetHeight(h)

        -- tables: an outlined rounded box, rows split by lines (no column lines)
        local n = 0
        local function hline(x1, y1, x2)
            n = n + 1
            local t = row.lines[n]
            if not t then
                t = row:CreateTexture(nil, "BORDER")
                Skin.Color(t, Skin.EDGE)
                row.lines[n] = t
            end
            t:ClearAllPoints()
            t:SetPoint("TOPLEFT", row, "TOPLEFT", x1, -y1)
            t:SetSize(math.max(1, x2 - x1), 1)
            t:Show()
        end
        row.hl:ClearAllPoints()
        if line.grid and line.cols then
            local last = line.cols[#line.cols]
            local right = last[2] + last[3]
            local prevGrid = i > 1 and lines[i - 1].grid
            local nextGrid = nextLine and nextLine.grid
            if not prevGrid then tableTop = y end
            if nextGrid then hline(1, h - 1, right - 1) end
            if not nextGrid then
                nTables = nTables + 1
                place(box(tableBoxes, nTables, Skin.CARD, Skin.EDGE, 8, -6), x, tableTop, right, y + h - tableTop)
            end
            row.hl:SetPoint("TOPLEFT", 1, prevGrid and 0 or -1)
            row.hl:SetPoint("BOTTOMRIGHT", row, "BOTTOMLEFT", right - 1, nextGrid and 1 or 1)
        else
            row.hl:SetAllPoints()
        end
        for k2 = n + 1, #row.lines do row.lines[k2]:Hide() end
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", x, -y)
        row:Show()
        y = y + h
    end
    closeCard()
    for i = #lines + 1, #rows do rows[i]:Hide() end
    for i = nCards + 1, #cardBoxes do cardBoxes[i]:Hide() end
    for i = nTables + 1, #tableBoxes do tableBoxes[i]:Hide() end
    content:SetHeight(y + 10)
    if scroll then scroll:Sync() end
end

-- Shift-click on a shopping-list item: same as shift-clicking it in your bags. With the AH
-- open the game (and Auctionator) search for it; otherwise the link goes into chat.
function UI.SearchItem(itemID)
    local GetInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
    local name, link = GetInfo(itemID)
    -- Same call a bag shift-click makes; the default AH and Auctionator both search on it.
    -- Newer clients use ChatFrameUtil.InsertLink (Auctionator hooks only that one there).
    local insert = (ChatFrameUtil and ChatFrameUtil.InsertLink) or ChatEdit_InsertLink
    if link and insert then
        insert(link)
        return
    end
    -- item details not loaded yet: type the name into the default AH search instead
    local bar = AuctionHouseFrame and AuctionHouseFrame:IsShown() and AuctionHouseFrame.SearchBar
    if bar and bar.SearchBox then
        bar.SearchBox:SetText(name or Name(itemID))
        if bar.StartSearch then bar:StartSearch() end
    end
end

local live = {} -- prof -> plan (with recipe tables), for this session
local stale = {} -- prof -> reason new data arrived since the plan was made

local tabs = {}

local function build()
    local f = CreateFrame("Frame", "CheapProfessionsFrame", UIParent)
    frame = f
    Skin.Panel(f)
    ns.db.window = ns.db.window or {}
    local win = ns.db.window
    f:SetSize(win.w or 660, win.h or 600)
    if win.x and win.y then
        f:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", win.x, win.y)
    else
        f:SetPoint("CENTER")
    end
    f:SetResizable(true)
    local function setMinWidth(minW)
        if f.SetResizeBounds then
            f:SetResizeBounds(minW, MIN_H, 1600, 1200)
        elseif f.SetMinResize then
            f:SetMinResize(minW, MIN_H)
        end
        if f:GetWidth() < minW then f:SetWidth(minW) end
    end
    local function savePos()
        win.x, win.y = f:GetLeft(), f:GetTop()
        win.w, win.h = f:GetWidth(), f:GetHeight()
    end
    f:SetMovable(true)
    f:SetClampedToScreen(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", function() f:StopMovingOrSizing() savePos() end)
    f:SetFrameStrata("HIGH")
    f:Hide()
    tinsert(UISpecialFrames, "CheapProfessionsFrame")

    -- title bar
    local bar = CreateFrame("Frame", nil, f)
    bar:SetPoint("TOPLEFT", 1, -1)
    bar:SetPoint("TOPRIGHT", -1, -1)
    bar:SetHeight(46)
    local title = Skin.FontString(bar, Skin.Heading())
    title:SetFontObject(Skin.Font("WindowTitle", "semibold", 15))
    title:SetPoint("LEFT", 16, -2)
    title:SetText(WHT .. "Cheap Professions" .. R)
    local close = Skin.CloseButton(bar)
    close:SetPoint("RIGHT", -10, -2)
    close:SetScript("OnClick", function() f:Hide() end)

    -- profession tabs, on a muted tab list
    local tabList = Skin.TabList(f)
    for _, prof in ipairs(ns.PROFESSIONS) do
        local name = ns.PROF_NAMES[prof]
        local b = Skin.Button(tabList, name, 80, 24, "tab")
        b:SetScript("OnClick", function()
            state.prof = prof
            state.start = nil
            scroll:ScrollToTop()
            UI.Refresh() -- shows the saved plan, or builds one if there is none
        end)
        tabs[prof] = b
    end

    -- controls
    local label = Skin.Label(f, "Start skill", true)
    label:SetPoint("TOPLEFT", 14, -82)
    startBox = Skin.EditBox(f, 48, 24)
    startBox:SetPoint("LEFT", label, "RIGHT", 8, 0)
    startBox:SetNumeric(true)
    startBox:SetScript("OnEnterPressed", function(self)
        state.start = tonumber(self:GetText())
        self:ClearFocus()
        UI.Replan()
    end)
    local hint = Skin.Label(f, "(blank = current)", true)
    hint:SetTextColor(Skin.FAINT[1], Skin.FAINT[2], Skin.FAINT[3])
    hint:SetPoint("LEFT", startBox, "RIGHT", 6, 0)

    local tlabel = Skin.Label(f, "Target skill", true)
    tlabel:SetPoint("LEFT", hint, "RIGHT", 20, 0)
    targetBox = Skin.EditBox(f, 48, 24)
    targetBox:SetPoint("LEFT", tlabel, "RIGHT", 8, 0)
    targetBox:SetNumeric(true)
    targetBox:SetScript("OnEnterPressed", function(self)
        setTarget(state.prof, tonumber(self:GetText()))
        self:ClearFocus()
        UI.Replan()
    end)

    local green = Skin.Check(f, 14)
    green:SetPoint("LEFT", targetBox, "RIGHT", 20, 0)
    local greenLabel = Skin.Label(green, "Avoid green", true)
    greenLabel:SetPoint("LEFT", green, "RIGHT", 6, 0)
    green:SetHitRectInsets(0, -(greenLabel:GetStringWidth() + 6), 0, 0)
    green:SetScript("OnShow", function(self) self:SetChecked(ns.db.opts.avoidGreen) end)
    green:SetScript("OnClick", function(self)
        ns.db.opts.avoidGreen = self:GetChecked() and true or false
        UI.Replan()
    end)
    green:SetChecked(ns.db.opts.avoidGreen)

    local refresh = Skin.Button(f, "Re-plan", 112, 32, "primary", Skin.Font("Primary", "semibold", 14))
    refresh:SetPoint("TOPRIGHT", -12, -77)
    refresh:SetScript("OnClick", function()
        -- Use what's in the box only if you changed it; otherwise plan from your current skill.
        local plan = state.prof and live[state.prof]
        local typed = tonumber(startBox:GetText())
        state.start = (typed and not (plan and typed == plan.start)) and typed or nil
        setTarget(state.prof, tonumber(targetBox:GetText()))
        UI.Replan()
    end)

    local div = Skin.Tex(f, "BORDER", Skin.EDGE)
    div:SetPoint("TOPLEFT", 1, -108)
    div:SetPoint("TOPRIGHT", -1, -108)
    div:SetHeight(1)

    scroll, content = Skin.Scroll(f, ROW_W)
    scroll:SetPoint("BOTTOMRIGHT", -26, 36)

    -- bottom bar: zoom (like a spreadsheet) next to the resize grip
    local foot = Skin.Tex(f, "BORDER", Skin.EDGE)
    foot:SetPoint("BOTTOMLEFT", 14, 30)
    foot:SetPoint("BOTTOMRIGHT", -14, 30)
    foot:SetHeight(1)
    local ZOOMS = { 0.5, 0.6, 0.7, 0.8, 0.9, 1, 1.1, 1.25, 1.5 }
    local zoomIdx
    local plus = Skin.Button(f, "+", 22, 20)
    plus:SetPoint("BOTTOMRIGHT", -26, 6)
    local pct = Skin.Button(f, "100%", 48, 20)
    pct:SetPoint("RIGHT", plus, "LEFT", -4, 0)
    local minus = Skin.Button(f, "-", 22, 20)
    minus:SetPoint("RIGHT", pct, "LEFT", -4, 0)
    local zlabel = Skin.Label(f, "Zoom", true)
    zlabel:SetPoint("RIGHT", minus, "LEFT", -6, 0)
    local function setZoom(i)
        zoomIdx = math.max(1, math.min(#ZOOMS, i))
        local z = ZOOMS[zoomIdx]
        ns.db.window.zoom = z
        pct:SetText(math.floor(z * 100 + 0.5) .. "%")
        scroll:SetZoom(z)
        setMinWidth(minWidth(z))
        if lastLines then setLines(lastLines) end
    end
    plus:SetScript("OnClick", function() setZoom(zoomIdx + 1) end)
    minus:SetScript("OnClick", function() setZoom(zoomIdx - 1) end)
    pct:SetScript("OnClick", function() for i, z in ipairs(ZOOMS) do if z == 1 then setZoom(i) end end end)
    for _, b in ipairs({ minus, pct, plus }) do
        b:HookScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            GameTooltip:AddLine("Zoom")
            GameTooltip:AddLine("Click the percentage to reset to 100%. Ctrl + mouse wheel over the plan also zooms.", 1, 1, 1, true)
            GameTooltip:Show()
        end)
        b:HookScript("OnLeave", function() GameTooltip:Hide() end)
    end
    scroll.OnZoomWheel = function(delta) setZoom(zoomIdx + (delta > 0 and 1 or -1)) end
    local saved = ns.db.window.zoom or 1
    zoomIdx = 6
    for i, z in ipairs(ZOOMS) do if math.abs(z - saved) < 0.01 then zoomIdx = i end end

    -- tabs share the width; the plan re-flows to the new width
    -- Narrow windows: tabs wrap onto a second row, and Avoid green / Re-plan move below
    -- the skill boxes.
    local function layout(w)
        local n = #ns.PROFESSIONS
        local gap, left, pad, minTab, tabH = 2, 14, 4, 116, 32
        local inner = w - 2 * left - 2 * pad
        local perRow = math.max(1, math.min(n, math.floor((inner + gap) / (minTab + gap))))
        local tabRows = math.ceil(n / perRow)
        perRow = math.ceil(n / tabRows) -- balance the rows
        local tabW = (inner - (perRow - 1) * gap) / perRow
        for i, prof in ipairs(ns.PROFESSIONS) do
            local r, c = math.floor((i - 1) / perRow), (i - 1) % perRow
            tabs[prof]:SetSize(tabW, tabH)
            tabs[prof]:ClearAllPoints()
            tabs[prof]:SetPoint("TOPLEFT", tabList, "TOPLEFT", pad + c * (tabW + gap), -pad - r * (tabH + gap))
        end
        local listH = 2 * pad + tabRows * tabH + (tabRows - 1) * gap
        tabList:ClearAllPoints()
        tabList:SetPoint("TOPLEFT", left, -46)
        tabList:SetSize(w - 2 * left, listH)
        local top = 46 + listH -- bottom of the tabs
        local wide = w >= 600
        label:ClearAllPoints()
        label:SetPoint("TOPLEFT", 16, -(top + 20))
        green:ClearAllPoints()
        refresh:ClearAllPoints()
        if wide then
            green:SetPoint("LEFT", targetBox, "RIGHT", 20, 0)
            refresh:SetPoint("TOPRIGHT", -14, -(top + 9))
        else
            green:SetPoint("TOPLEFT", 16, -(top + 20 + 32))
            refresh:SetPoint("TOPRIGHT", -14, -(top + 9 + 32))
        end
        local divY = top + 50 + (wide and 0 or 32)
        div:ClearAllPoints()
        div:SetPoint("TOPLEFT", 14, -divY)
        div:SetPoint("TOPRIGHT", -14, -divY)
        scroll:SetPoint("TOPLEFT", 14, -(divY + 12))
        scroll:SetViewWidth(w - 14 - 26)
    end
    local reflow = ns.Debounce(0.05, function()
        layout(f:GetWidth())
        if lastLines then setLines(lastLines) end
        scroll.Update()
    end)
    f:SetScript("OnSizeChanged", reflow)
    layout(f:GetWidth())
    setZoom(zoomIdx)

    -- resize grip (bottom-right corner)
    local grip = CreateFrame("Button", nil, f)
    grip:SetSize(16, 16)
    grip:SetPoint("BOTTOMRIGHT", -4, 4)
    local dots = {}
    for _, d in ipairs({ { 0, 0 }, { 4, 0 }, { 8, 0 }, { 0, 4 }, { 4, 4 }, { 0, 8 } }) do
        local t = Skin.Tex(grip, "OVERLAY", Skin.THUMB)
        t:SetSize(2, 2)
        t:SetPoint("BOTTOMRIGHT", -2 - d[1], 2 + d[2])
        dots[#dots + 1] = t
    end
    local function paintGrip(c) for _, t in ipairs(dots) do Skin.Color(t, c) end end
    grip:SetScript("OnEnter", function() paintGrip(Skin.DIM) end)
    grip:SetScript("OnLeave", function() paintGrip(Skin.THUMB) end)
    grip:SetScript("OnMouseDown", function() f:StartSizing("BOTTOMRIGHT") end)
    grip:SetScript("OnMouseUp", function()
        f:StopMovingOrSizing()
        savePos()
        reflow()
    end)
end

-- Builds the plan without your ticked recipes (wizard step 1/2) and, if any are ticked, with them.
function UI.Compute(prof, start, target)
    local base, err = ns.Planner.Build(prof, start, target, nil)
    if not base then return nil, err end
    local planned = ns.Planned(prof)
    if next(planned) == nil then return base end
    local plan = ns.Planner.Build(prof, start, target, planned)
    plan.baseline = base
    return plan
end

---------------------------------------------------------------------------
-- Saved plans. A plan stays exactly as built (prices, bags, quantities) until the player
-- asks for a new one, so buying materials doesn't change the list being bought from.
-- Plans are stored per character and profession, with recipes stored by key.
---------------------------------------------------------------------------
local function isRecipe(t)
    return type(t) == "table" and t.rg and t.k and t.n
end

local function freeze(v, prof)
    if type(v) ~= "table" then return v end
    if isRecipe(v) then return { __rec = ns.RecipeKey(v) } end
    local out = {}
    for k, x in pairs(v) do out[k] = freeze(x, prof) end
    return out
end

local function thaw(v, byKey)
    if type(v) ~= "table" then return v end
    if v.__rec then return byKey[v.__rec] end
    local out = {}
    for k, x in pairs(v) do out[k] = thaw(x, byKey) end
    return out
end

UI._freeze, UI._thaw = freeze, thaw -- for the offline test

local function savedPlan(prof)
    if live[prof] then return live[prof] end
    local stored = ns.cdb.plans and ns.cdb.plans[prof]
    if not stored then return end
    local byKey = {}
    for _, rec in ipairs(ns.Data.recipes[prof] or {}) do byKey[ns.RecipeKey(rec)] = rec end
    local ok, plan = pcall(thaw, stored, byKey)
    if ok and plan and plan.steps then
        live[prof] = plan
        return plan
    end
end

local function storePlan(prof, plan)
    live[prof] = plan
    ns.cdb.plans = ns.cdb.plans or {}
    ns.cdb.plans[prof] = freeze(plan, prof)
end

-- Draw the saved plan for the selected profession (no recalculation).
-- When Auctionator last started an AH scan (full or quick), or nil.
local function lastScanTime()
    local st = Auctionator and Auctionator.SavedState
    if type(st) ~= "table" then return end
    local t
    for _, k in ipairs({ "TimeOfLastReplicateScan", "TimeOfLastBrowseScan", "TimeOfLastGetAllScan" }) do
        if type(st[k]) == "number" and (not t or st[k] > t) then t = st[k] end
    end
    return t
end

-- Redraw when you leave the AH, so a scan you just did shows up in the notice.
ns.On("AUCTION_HOUSE_CLOSED", function() UI.Refresh() end)

function UI.Refresh()
    if not frame or not frame:IsShown() then return end
    for prof, b in pairs(tabs) do b:SetSelected(prof == state.prof) end
    if not state.prof then
        setLines({
            { text = "Pick a profession above." },
            { text = "" },
            { text = "Prices come from your latest Auctionator scan; do a full scan first for best results." },
        })
        return
    end
    local plan = savedPlan(state.prof)
    if not plan then return UI.Replan() end
    startBox:SetText(tostring(plan.start))
    targetBox:SetText(tostring(plan.target))
    local lines = render(plan)
    local head = {}
    head[#head + 1] = { text = ("%sPlan made %s from skill %d.%s"):format(
        GRY, date("%b %d %H:%M", plan.builtAt or time()), plan.start, R) }
    if stale[state.prof] then
        head[#head + 1] = { text = ORA .. stale[state.prof] .. " Press Re-plan to use it." .. R }
    end
    local scanned = lastScanTime()
    if scanned and plan.builtAt and scanned > plan.builtAt then
        head[#head + 1] = { text = ("%sYou scanned the AH %s, after this plan was made. Press Re-plan to use the new prices.%s"):format(
            ORA, date("%b %d %H:%M", scanned), R) }
    end
    head[#head + 1] = { text = "" }
    for i = #head, 1, -1 do table.insert(lines, 1, head[i]) end
    setLines(lines)
end

-- Build a new plan for the selected profession from current prices, bags and settings.
function UI.Replan()
    if not frame or not frame:IsShown() or not state.prof then return end
    local start = state.start
    if not start then
        local rank = ns.CharSkill(state.prof)
        start = rank or 1
    end
    local target = getTarget(state.prof)
    startBox:SetText(tostring(start))
    targetBox:SetText(tostring(target))
    if start >= target then
        setLines({ { text = ("Start skill %d is already at or above the target %d."):format(start, target) } })
        return
    end
    local ok, plan = pcall(UI.Compute, state.prof, start, target)
    if not ok then
        setLines({ { text = RED .. "Planner error: " .. tostring(plan) .. R } })
        geterrorhandler()(plan)
        return
    elseif not plan then
        setLines({ { text = "Nothing to plan." } })
        return
    end
    plan.builtAt = time()
    storePlan(state.prof, plan)
    stale[state.prof] = ns.Prices.HasPending()
        and "Some item details were still loading when this plan was made, so sale values may be low." or nil
    UI.Refresh()
end

-- Settings changed: rebuild the open plan; other saved plans just get a notice.
function UI.SettingsChanged()
    for _, prof in ipairs(ns.PROFESSIONS) do
        if prof ~= state.prof or not (frame and frame:IsShown()) then
            if savedPlan(prof) then stale[prof] = "Settings changed since this plan was made." end
        end
    end
    if frame and frame:IsShown() and state.prof then UI.Replan() end
end

-- New trainer/recipe data arrived: keep the plan, but say so.
function UI.MarkStale(prof, reason)
    if prof then stale[prof] = reason end
    UI.Refresh()
end

-- Redraw only (e.g. item names finished loading).
UI.RefreshSoon = ns.Debounce(0.5, function() UI.Refresh() end)

function UI.Show(prof, start, target)
    if not frame then build() end
    if prof then state.prof = prof end
    state.start = start
    if prof and target then setTarget(prof, target) end
    frame:Show()
    if start or target then UI.Replan() else UI.Refresh() end
end

function UI.Toggle()
    if frame and frame:IsShown() then
        frame:Hide()
    else
        UI.Show()
    end
end
