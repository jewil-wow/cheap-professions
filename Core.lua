local addonName, ns = ...

ns.Data = {}
_G.JewilProf = ns -- handy for /dump while developing

local DB_DEFAULTS = {
    -- items whose crafted output is valued at AH price (minus cut) instead of vendor price
    ahSell = {},
    ahSellSeeded = false,
    -- learned from trainer windows: trainer[prof][recipeKey] = { skill = n, cost = copper }
    trainer = {},
    -- learned from the profession window: yields[prof][recipeKey] = numMade
    yields = {},
    -- per-profession target skill (absent = 300)
    targets = {},
    opts = {
        useBags = true,      -- count reagents in bags/bank as free
        includeBooks = true, -- consider recipes you'd have to buy (priced from AH / vendor)
        includeRep = false,  -- consider recipes that need reputation
        avoidGreen = true,   -- don't plan green crafts unless nothing else covers a skill point
        maxAgeDays = 3,      -- ignore AH prices older than this many days
        thinRatio = 0.5,     -- flag a reagent when the plan needs more than this share of the listed supply
        ahCut = 0.05,
    },
}

local CHAR_DEFAULTS = {
    plans = {},   -- plans[prof] = the last plan built (kept until Re-plan)
    known = {},   -- known[prof][recipeKey] = true
    planned = {}, -- planned[prof][recipeKey] = true: recipes the player intends to obtain
}

local function applyDefaults(dst, src)
    for k, v in pairs(src) do
        if dst[k] == nil then
            dst[k] = type(v) == "table" and CopyTable(v) or v
        elseif type(v) == "table" and type(dst[k]) == "table" then
            applyDefaults(dst[k], v)
        end
    end
end

ns.PROFESSIONS = { "alchemy", "blacksmithing", "enchanting", "engineering", "leatherworking", "tailoring", "cooking", "firstaid" }
ns.PROF_NAMES = {
    alchemy = "Alchemy", blacksmithing = "Blacksmithing", enchanting = "Enchanting", engineering = "Engineering",
    leatherworking = "Leatherworking", tailoring = "Tailoring", cooking = "Cooking", firstaid = "First Aid",
}
ns.MAX_SKILL = 300

function ns.Print(...)
    print("|cff66ccffJewilProf|r:", ...)
end

function ns.RecipeKey(rec)
    return rec.i and ("i:" .. rec.i) or ("s:" .. rec.sp)
end

-- Profession key from a skill line id or an (English) profession name.
function ns.ProfKey(lineOrName)
    if type(lineOrName) == "number" then
        for key, line in pairs(ns.Data.skillLines) do
            if line == lineOrName then return key end
        end
    elseif type(lineOrName) == "string" then
        local n = lineOrName:lower():gsub("[%s%-]", "")
        if ns.Data.recipes[n] then return n end
        for key, name in pairs(ns.PROF_NAMES) do
            if name:lower() == lineOrName:lower() then return key end
        end
    end
end

-- Current skill and max skill for a profession on this character (nil if not learned).
function ns.CharSkill(prof)
    if GetProfessions and GetProfessionInfo then
        for _, idx in pairs({ GetProfessions() }) do
            if idx then
                local name, _, rank, maxRank, _, _, line = GetProfessionInfo(idx)
                if ns.ProfKey(line) == prof or ns.ProfKey(name) == prof then
                    return rank, maxRank
                end
            end
        end
    end
    if GetNumSkillLines and GetSkillLineInfo then
        for i = 1, GetNumSkillLines() do
            local name, isHeader, _, rank, _, _, maxRank = GetSkillLineInfo(i)
            if not isHeader and ns.ProfKey(name) == prof then return rank, maxRank end
        end
    end
end

local frame = CreateFrame("Frame")
ns.EventFrame = frame
local handlers = {}
function ns.On(event, fn)
    handlers[event] = handlers[event] or {}
    table.insert(handlers[event], fn)
    frame:RegisterEvent(event)
end
frame:SetScript("OnEvent", function(_, event, ...)
    for _, fn in ipairs(handlers[event] or {}) do
        local ok, err = pcall(fn, ...)
        if not ok then geterrorhandler()(err) end
    end
end)

ns.On("ADDON_LOADED", function(name)
    if name ~= addonName then return end
    JewilProfDB = JewilProfDB or {}
    JewilProfCharDB = JewilProfCharDB or {}
    applyDefaults(JewilProfDB, DB_DEFAULTS)
    applyDefaults(JewilProfCharDB, CHAR_DEFAULTS)
    ns.db, ns.cdb = JewilProfDB, JewilProfCharDB

    if not ns.db.ahSellSeeded then
        -- Items known to sell on the AH during levelling. Add more with /jp ahsell add <item>.
        local seed = { ["Hillman's Cloak"] = true }
        for _, list in pairs(ns.Data.recipes) do
            for _, rec in ipairs(list) do
                if rec.i and seed[rec.n] then ns.db.ahSell[rec.i] = true end
            end
        end
        ns.db.ahSellSeeded = true
    end
end)

function ns.Planned(prof)
    ns.cdb.planned[prof] = ns.cdb.planned[prof] or {}
    return ns.cdb.planned[prof]
end

-- Debounced callback helper.
function ns.Debounce(delay, fn)
    local pending = false
    return function()
        if pending then return end
        pending = true
        C_Timer.After(delay, function()
            pending = false
            fn()
        end)
    end
end

local function itemFromArg(arg)
    if not arg then return end
    local id = tonumber(arg) or tonumber(arg:match("item:(%d+)"))
    if id then return id end
    local lower = arg:lower()
    for _, list in pairs(ns.Data.recipes) do
        for _, rec in ipairs(list) do
            if rec.i and rec.n:lower() == lower then return rec.i end
        end
    end
end

local HELP = {
    "/jp - toggle the planner window",
    "/jp <profession> [start] [target] - plan a profession (e.g. /jp tailoring 120 250)",
    "/jp ahsell add|remove <item link, id or name> - value a crafted item at AH price",
    "/jp ahsell list",
    "/jp opt bags|books|rep|green on|off - count bag items as free / buy recipes / allow reputation recipes / allow green crafts",
}

SLASH_JEWILPROF1 = "/jp"
SLASH_JEWILPROF2 = "/jewilprof"
SlashCmdList.JEWILPROF = function(msg)
    msg = strtrim(msg or "")
    local cmd, rest = msg:match("^(%S*)%s*(.-)$")
    cmd = cmd:lower()
    if cmd == "" then
        ns.UI.Toggle()
    elseif cmd == "help" then
        for _, l in ipairs(HELP) do ns.Print(l) end
    elseif cmd == "ahsell" then
        local sub, arg = rest:match("^(%S*)%s*(.-)$")
        sub = sub:lower()
        if sub == "list" or sub == "" then
            ns.Print("Valued at AH price:")
            for id in pairs(ns.db.ahSell) do ns.Print("  ", ns.Prices.ItemName(id), "(" .. id .. ")") end
        else
            local id = itemFromArg(arg)
            if not id then return ns.Print("Unknown item:", arg) end
            ns.db.ahSell[id] = (sub == "add") or nil
            ns.Print(sub == "add" and "Added" or "Removed", ns.Prices.ItemName(id))
            ns.UI.SettingsChanged()
        end
    elseif cmd == "opt" then
        local name, val = rest:match("^(%S+)%s+(%S+)$")
        local map = { bags = "useBags", books = "includeBooks", rep = "includeRep", green = "avoidGreen" }
        if not (name and map[name:lower()]) then return ns.Print("Usage: /jp opt bags|books|rep|green on|off") end
        local on = val:lower() == "on"
        if name:lower() == "green" then on = not on end -- "green on" = allow green crafts
        ns.db.opts[map[name:lower()]] = on
        ns.Print(name, "=", val)
        ns.UI.SettingsChanged()
    else
        local prof = ns.ProfKey(cmd)
        if not prof then
            for _, l in ipairs(HELP) do ns.Print(l) end
            return
        end
        local a, b = rest:match("^(%S*)%s*(%S*)")
        ns.UI.Show(prof, tonumber(a), tonumber(b))
    end
end
