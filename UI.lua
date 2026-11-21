-- UI.lua: the planner window. Each line is a row; hover a step for the details behind its numbers.
local _, ns = ...

local UI = {}
ns.UI = UI

local Money = function(c) return ns.Prices.Money(c) end
local Name = function(id) return ns.Prices.ItemName(id) end

local RED, YEL, GRY, GRN, ORA, BLU, WHT = "|cffff5555", "|cffffd100", "|cff999999", "|cff55ff55", "|cffff8040", "|cff66ccff", "|cffffffff"
local R = "|r"

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
                local p = ns.Prices.AH(x.item)
                parts[#parts + 1] = ("%s AH @ %s"):format(cnt(m.ah), p and Money(p) or "?")
            end
            if m.vendor > 1e-6 then
                local p, seed = ns.Prices.Vendor(x.item)
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

local function render(plan)
    local L = {}
    local function add(s, tip, check) L[#L + 1] = { text = s or "", tip = tip, check = check } end
    local function addCols(cols, tip) L[#L + 1] = { text = "", cols = cols, tip = tip } end
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

    add(("%s%s|r  %d -> %d"):format(YEL, ns.PROF_NAMES[plan.prof], plan.start, plan.target))
    add()
    add(YEL .. "Step 1|r - Run a full scan with Auctionator to get the latest prices.")
    add(("Using your latest scan, it will cost about %s%s|r to level."):format(WHT, Money(base.totals.net)))
    add()
    add(YEL .. "Step 2|r - Optional Recipes" .. R)
    if #lookFor == 0 then
        add(GRY .. "None: no recipe missing from the AH would save you money on this plan." .. R)
    else
        add(GRY .. "These recipes aren't listed on the AH, but could save you some money if you obtained them. The gold amount next to the recipe is the approximate amount you would save if you got the recipe for free." .. R)
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
            local title = m.rec.book and Name(m.rec.book)
                or (m.rec.n .. GRY .. " (not taught by trainers: quest, specialization or other)" .. R)
            add(("%s - %s%s  %slearn at %s%s%s"):format(title, gain, rep, GRY, tostring(learn or "?"), R, unused), nil, {
                checked = planned[key] and true or false,
                onClick = function(checked)
                    planned[key] = checked or nil
                    UI.Refresh()
                end,
            })
        end
    end
    add()
    local nPlanned = 0
    for _ in pairs(usedPlanned) do nPlanned = nPlanned + 1 end
    local saved = nPlanned > 0 and (GRN .. ("  (saves %s)"):format(Money(base.totals.net - t.net)) .. R) or ""
    add(YEL .. "Step 3|r - Shopping List" .. R)
    add(("Updated cost using optional recipes: %s%s|r%s"):format(WHT, Money(t.net), saved))
    add()
    add(("%smaterials: AH %s + vendor %s, recipes %s, minus sales %s%s"):format(
        GRY, Money(t.ah), Money(t.vendor), Money(t.recipes), Money(t.sale), R))
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
        add(YEL .. "Recipes" .. R)
        add(GRY .. "Prices are current AH price. Check wowhead for vendor price/location and feel free to travel to the vendor if it's worth the cost savings." .. R)
        add()
        for _, a in ipairs(purchase) do
            local note = a.how == "vendor" and (GRY .. " (vendor price you've seen)" .. R) or ""
            add(("  %3d  %s  %s%s"):format(a.learn, Name(a.rec.book), Money(a.cost), note))
        end
        add()
    end

    add(YEL .. "Materials" .. R)
    add(GRY .. "If the total cost you see on the AH is much different than this table, rescan the AH." .. R)
    add()
    local C1, C2, C3, C4 = 0, 300, 390, 490
    addCols({
        { YEL .. "Item" .. R, C1, 290, "LEFT" }, { YEL .. "Quantity" .. R, C2, 80, "RIGHT" },
        { YEL .. "Cost per Item" .. R, C3, 95, "RIGHT" }, { YEL .. "Total Cost" .. R, C4, 95, "RIGHT" },
    })
    local grand, anyThin, anySeed, anyBags = 0, false, false, false
    for _, row in ipairs(plan.shopping) do
        local qty = row.ah + row.vendor
        local total = row.ahCost + row.vendorCost
        local bags = math.floor(row.bags + 1e-6)
        local name = Name(row.item)
        if row.thin then name = RED .. "! " .. R .. name; anyThin = true end
        if row.vendor > 0 and row.ah == 0 then name = name .. GRY .. " (vendor)" .. R end
        if bags > 0 then name = name .. GRN .. (" (+%d from bags)"):format(bags) .. R; anyBags = true end
        if row.stale then name = name .. RED .. (" seen %dd ago"):format(row.age) .. R end
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
            { name, C1, 290, "LEFT" }, { tostring(qty), C2, 80, "RIGHT" },
            { (seed and "~" or "") .. Money(unit), C3, 95, "RIGHT" }, { Money(total), C4, 95, "RIGHT" },
        })
    end
    addCols({ { WHT .. "Total" .. R, C1, 290, "LEFT" }, { WHT .. Money(grand) .. R, C4, 95, "RIGHT" } })
    local notes = {}
    if anyThin then notes[#notes + 1] = "! = the plan needs much of what's listed; it may sell out, so buy these first" end
    if anySeed then notes[#notes + 1] = "~ = approximate vendor price" end
    if anyBags then notes[#notes + 1] = "items from your bags are free and not counted" end
    if #notes > 0 then add(GRY .. table.concat(notes, ". ") .. "." .. R) end
    add()

    add(YEL .. "Step 4|r - Craft" .. GRY .. "  (hover a step for its materials and prices)" .. R)
    local estimated = {}
    for _, a in ipairs(plan.acquire) do
        if not a.exact then estimated[a.rec] = true end
    end
    local capIdx = 1
    while RANK_CAPS[capIdx] and RANK_CAPS[capIdx] <= plan.start do capIdx = capIdx + 1 end
    for _, st in ipairs(plan.steps) do
        while RANK_CAPS[capIdx] and st.to > RANK_CAPS[capIdx] do
            local td = ns.Data.trainerData and ns.Data.trainerData[plan.prof]
            local at = td and td.ranks[capIdx]
            local when = at and (" (learnable at " .. at .. ")") or ""
            add(("  %s-- train the next rank%s before %d --%s"):format(BLU, when, RANK_CAPS[capIdx], R))
            capIdx = capIdx + 1
        end
        local greenTxt = st.green and (GRN .. " (green)" .. R) or ""
        local fromEarlier = {}
        for item, m in pairs(st.mats) do
            if m.stock > 0.5 then fromEarlier[#fromEarlier + 1] = cnt(m.stock) .. " " .. Name(item) end
        end
        local earlierTxt = #fromEarlier > 0 and (" + " .. table.concat(fromEarlier, ", ") .. " from earlier steps") or ""
        local keepTxt = ""
        if st.keep and st.keep >= 0.5 then
            local all = st.keep >= st.made - 0.5
            keepTxt = ORA .. (all and " - save them all for later steps" or (" - save " .. cnt(st.keep) .. " for later steps")) .. R
        end
        add(("  %3d-%-3d  %s%s%s|r x%s%s%s   %smats %s%s%s"):format(
            st.from, st.to, WHT, (usedPlanned[st.rec] and (BLU .. "*" .. WHT) or "") .. (estimated[st.rec] and (ORA .. "~" .. WHT) or ""), st.rec.n, cnt(st.crafts), greenTxt, keepTxt,
            GRY, Money(st.reagents), earlierTxt, R), stepTip(st))
        local prep = {}
        for item, q in pairs(st.prep) do prep[#prep + 1] = { item = item, q = q } end
        table.sort(prep, function(a, b) return a.q > b.q end)
        for _, p in ipairs(prep) do
            local g = st.prepGain[p.item] or 0
            local gainTxt = g >= 0.5 and ("~" .. math.floor(g + 0.5) .. " skill-ups") or "no skill-ups"
            add(("             %sfirst craft %s x %s (%s), used in this step%s"):format(GRY, cnt(p.q), Name(p.item), gainTxt, R))
        end
    end
    add()

    if #plan.sales > 0 then
        add(YEL .. "Sales" .. R .. GRY .. "  (crafted items not needed by later steps)" .. R)
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
local frame, content, startBox, targetBox
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
local ROW_W = 590

local function getRow(i)
    local row = rows[i]
    if row then return row end
    row = CreateFrame("Button", nil, content)
    row:SetWidth(ROW_W)
    row.fs = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.fs:SetJustifyH("LEFT")
    row.check = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
    row.check:SetSize(20, 20)
    row.check:SetPoint("LEFT", -2, 0)
    row.check:SetScript("OnClick", function(self)
        if self.onClick then self.onClick(self:GetChecked() and true or false) end
    end)
    row.hl = row:CreateTexture(nil, "BACKGROUND")
    row.hl:SetAllPoints()
    row.hl:SetColorTexture(1, 1, 1, 0.08)
    row.hl:Hide()
    row:SetScript("OnEnter", function(self)
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

local function setLines(lines)
    local y = 0
    for i, line in ipairs(lines) do
        local row = getRow(i)
        row.cols = row.cols or {}
        for c = 1, math.max(#row.cols, line.cols and #line.cols or 0) do
            local col = line.cols and line.cols[c]
            local fs = row.cols[c]
            if col then
                if not fs then
                    fs = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
                    row.cols[c] = fs
                end
                fs:ClearAllPoints()
                fs:SetPoint("TOPLEFT", col[2], 0)
                fs:SetWidth(col[3])
                fs:SetJustifyH(col[4])
                fs:SetWordWrap(false)
                fs:SetText(col[1])
                fs:Show()
            elseif fs then
                fs:Hide()
            end
        end
        local indent = line.check and 20 or 0
        row.fs:ClearAllPoints()
        row.fs:SetPoint("TOPLEFT", indent, line.check and -4 or 0)
        row.fs:SetWidth(ROW_W - indent)
        row.fs:SetText(line.text ~= "" and line.text or " ")
        row.tip = line.tip
        if line.check then
            row.check:SetChecked(line.check.checked)
            row.check.onClick = line.check.onClick
            row.check:Show()
        else
            row.check.onClick = nil
            row.check:Hide()
        end
        local h = math.max(line.check and 20 or 12, row.fs:GetStringHeight() + (line.check and 6 or 0)) + 2
        row:SetHeight(h)
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", 0, -y)
        row:Show()
        y = y + h
    end
    for i = #lines + 1, #rows do rows[i]:Hide() end
    content:SetHeight(y + 10)
end

local function build()
    local ok, f = pcall(CreateFrame, "Frame", "JewilProfFrame", UIParent, "BasicFrameTemplateWithInset")
    if not ok then f = CreateFrame("Frame", "JewilProfFrame", UIParent, "BackdropTemplate") end
    frame = f
    f:SetSize(660, 580)
    f:SetPoint("CENTER")
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:SetFrameStrata("HIGH")
    f:Hide()
    tinsert(UISpecialFrames, "JewilProfFrame")
    if f.TitleText then f.TitleText:SetText("JewilProf - cheapest levelling") end

    for i, prof in ipairs(ns.PROFESSIONS) do
        local b = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
        b:SetSize(78, 22)
        b:SetPoint("TOPLEFT", 12 + (i - 1) * 79, -30)
        b:SetText((ns.PROF_NAMES[prof]:gsub("smithing", "smith"):gsub("working", "work"):gsub("Engineering", "Engineer")))
        b:SetScript("OnClick", function()
            state.prof = prof
            state.start = nil
            UI.Refresh()
        end)
    end

    local label = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    label:SetPoint("TOPLEFT", 16, -60)
    label:SetText("Start skill:")
    startBox = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
    startBox:SetSize(50, 20)
    startBox:SetPoint("LEFT", label, "RIGHT", 10, 0)
    startBox:SetAutoFocus(false)
    startBox:SetNumeric(true)
    startBox:SetScript("OnEnterPressed", function(self)
        state.start = tonumber(self:GetText())
        self:ClearFocus()
        UI.Refresh()
    end)
    local hint = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hint:SetPoint("LEFT", startBox, "RIGHT", 6, 0)
    hint:SetText("(blank = current)")

    local tlabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    tlabel:SetPoint("LEFT", hint, "RIGHT", 20, 0)
    tlabel:SetText("Target skill:")
    targetBox = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
    targetBox:SetSize(50, 20)
    targetBox:SetPoint("LEFT", tlabel, "RIGHT", 10, 0)
    targetBox:SetAutoFocus(false)
    targetBox:SetNumeric(true)
    targetBox:SetScript("OnEnterPressed", function(self)
        setTarget(state.prof, tonumber(self:GetText()))
        self:ClearFocus()
        UI.Refresh()
    end)

    local refresh = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    refresh:SetSize(90, 22)
    refresh:SetPoint("TOPRIGHT", -14, -56)
    refresh:SetText("Re-plan")
    refresh:SetScript("OnClick", function()
        state.start = tonumber(startBox:GetText())
        setTarget(state.prof, tonumber(targetBox:GetText()))
        UI.Refresh()
    end)

    local green = CreateFrame("CheckButton", nil, f, "UICheckButtonTemplate")
    green:SetSize(22, 22)
    green:SetPoint("LEFT", targetBox, "RIGHT", 14, 0)
    local greenLabel = green:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    greenLabel:SetPoint("LEFT", green, "RIGHT", 2, 0)
    greenLabel:SetText("Avoid green")
    green:SetScript("OnShow", function(self) self:SetChecked(ns.db.opts.avoidGreen) end)
    green:SetScript("OnClick", function(self)
        ns.db.opts.avoidGreen = self:GetChecked() and true or false
        UI.Refresh()
    end)
    green:SetChecked(ns.db.opts.avoidGreen)

    local scroll = CreateFrame("ScrollFrame", nil, f, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 12, -86)
    scroll:SetPoint("BOTTOMRIGHT", -32, 12)
    content = CreateFrame("Frame", nil, scroll)
    content:SetSize(ROW_W, 10)
    scroll:SetScrollChild(content)
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

function UI.Refresh()
    if not frame or not frame:IsShown() then return end
    if not state.prof then
        setLines({
            { text = "Pick a profession above." },
            { text = "" },
            { text = "Prices come from your latest Auctionator scan; do a full scan first for best results." },
        })
        return
    end
    local start = state.start
    if not start then
        local rank = ns.CharSkill(state.prof)
        start = rank or 1
    end
    startBox:SetText(tostring(start))
    local target = getTarget(state.prof)
    targetBox:SetText(tostring(target))
    if start >= target then
        setLines({ { text = ("Start skill %d is already at or above the target %d."):format(start, target) } })
        return
    end
    local t0 = debugprofilestop()
    local ok, plan = pcall(UI.Compute, state.prof, start, target)
    if not ok then
        setLines({ { text = RED .. "Planner error: " .. tostring(plan) .. R } })
        geterrorhandler()(plan)
    elseif not plan then
        setLines({ { text = "Nothing to plan." } })
    else
        local lines = render(plan)
        lines[#lines + 1] = { text = "" }
        lines[#lines + 1] = { text = ("%splanned in %.0f ms%s"):format(GRY, debugprofilestop() - t0, R) }
        setLines(lines)
    end
end

UI.RefreshSoon = ns.Debounce(0.5, function() UI.Refresh() end)

function UI.Show(prof, start, target)
    if not frame then build() end
    if prof then state.prof = prof end
    state.start = start
    if prof and target then setTarget(prof, target) end
    frame:Show()
    UI.Refresh()
end

function UI.Toggle()
    if frame and frame:IsShown() then
        frame:Hide()
    else
        UI.Show()
    end
end
