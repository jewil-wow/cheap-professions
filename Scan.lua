-- Scan.lua: learn facts the static data lacks from the game's own windows.
--   * profession window: which recipes this character knows, and how many items a craft makes
--   * trainer window: the exact skill needed to learn each trainer recipe, and its cost
local _, ns = ...

local Scan = {}
ns.Scan = Scan

-- index[prof] = { byItem = {itemID = {rec, ...}}, bySpell = {spellID = rec}, byName = {lowername = {rec, ...}} }
local index = {}
function Scan.Index(prof)
    if index[prof] then return index[prof] end
    local ix = { byItem = {}, bySpell = {}, byName = {} }
    for _, rec in ipairs(ns.Data.recipes[prof] or {}) do
        if rec.sp then ix.bySpell[rec.sp] = rec end
        if rec.i then
            ix.byItem[rec.i] = ix.byItem[rec.i] or {}
            table.insert(ix.byItem[rec.i], rec)
        end
        local lname = rec.n:lower()
        ix.byName[lname] = ix.byName[lname] or {}
        table.insert(ix.byName[lname], rec)
    end
    index[prof] = ix
    return ix
end

local function onlyOne(list)
    return list and #list == 1 and list[1] or nil
end

local function tradeSkillProf()
    local C = C_TradeSkillUI
    if not C then return end
    if (C.IsTradeSkillLinked and C.IsTradeSkillLinked()) or (C.IsNPCCrafting and C.IsNPCCrafting())
        or (C.IsTradeSkillGuild and C.IsTradeSkillGuild()) then
        return
    end
    if C.GetBaseProfessionInfo then
        local info = C.GetBaseProfessionInfo()
        if info then
            local key = ns.ProfKey(info.professionID) or ns.ProfKey(info.professionName)
            if key then return key end
        end
    end
    if C.GetTradeSkillLine then
        local id, name = C.GetTradeSkillLine()
        return ns.ProfKey(id) or ns.ProfKey(name)
    end
end

function Scan.TradeSkill()
    local C = C_TradeSkillUI
    if not (C and C.GetAllRecipeIDs) then return end
    local prof = tradeSkillProf()
    if not prof then return end
    local ix = Scan.Index(prof)
    local known = {}
    ns.db.yields[prof] = ns.db.yields[prof] or {}
    local yields = ns.db.yields[prof]
    local matched = 0
    for _, id in ipairs(C.GetAllRecipeIDs() or {}) do
        local info = C.GetRecipeInfo(id)
        local okS, schem = pcall(C.GetRecipeSchematic, id, false)
        local out = okS and schem and schem.outputItemID
        local rec = ix.bySpell[id]
            or (out and onlyOne(ix.byItem[out]))
            or (info and info.name and onlyOne(ix.byName[info.name:lower()]))
        if rec then
            local key = ns.RecipeKey(rec)
            if info and info.learned then
                known[key] = true
                matched = matched + 1
            end
            local made = okS and schem and schem.quantityMin
            if made and made > 1 then yields[key] = made end
        end
    end
    -- Only overwrite when the list actually loaded (it can be empty on the first event).
    if matched > 0 then
        ns.cdb.known[prof] = known
        if ns.UI then ns.UI.MarkStale(prof, "Your known recipes were updated.") end
    end
end

local scanSoon = ns.Debounce(0.3, Scan.TradeSkill)
ns.On("TRADE_SKILL_SHOW", scanSoon)
ns.On("TRADE_SKILL_LIST_UPDATE", scanSoon)
ns.On("NEW_RECIPE_LEARNED", scanSoon)

local function trainerMatches(prof, i, name)
    local list = Scan.Index(prof).byName[name:lower()]
    if not list then return end
    if #list > 1 and GetTrainerServiceItemLink then
        local link = GetTrainerServiceItemLink(i)
        local itemID = link and tonumber(link:match("item:(%d+)"))
        if itemID then
            local matched = {}
            for _, rec in ipairs(list) do
                if rec.i == itemID then matched[#matched + 1] = rec end
            end
            if #matched > 0 then return matched end
        end
    end
    return list
end

local lastTrainerCount
function Scan.Trainer()
    if not (GetNumTrainerServices and GetTrainerServiceSkillReq) then return end
    local n = GetNumTrainerServices() or 0
    local updated = 0
    for i = 1, n do
        local name = GetTrainerServiceInfo(i)
        local skillName, skillRank = GetTrainerServiceSkillReq(i)
        local prof = skillName and ns.ProfKey(skillName)
        if prof and name then
            local recs = trainerMatches(prof, i, name)
            if recs then
                ns.db.trainer[prof] = ns.db.trainer[prof] or {}
                local skill = skillRank or 0
                local cost = GetTrainerServiceCost and GetTrainerServiceCost(i) or nil
                for _, rec in ipairs(recs) do
                    ns.db.trainer[prof][ns.RecipeKey(rec)] = {
                        skill = skill,
                        cost = cost,
                    }
                end
                updated = updated + 1
            end
        end
    end
    if updated > 0 and updated ~= lastTrainerCount then
        lastTrainerCount = updated
        ns.Print(("Recorded %d trainer recipes (learn levels and costs)."):format(updated))
        if ns.UI then
            for prof in pairs(ns.db.trainer) do ns.UI.MarkStale(prof, "New trainer data was recorded.") end
        end
    end
end

local trainerSoon = ns.Debounce(0.3, Scan.Trainer)
ns.On("TRAINER_SHOW", function() lastTrainerCount = nil; trainerSoon() end)
ns.On("TRAINER_UPDATE", trainerSoon)
