-- Dev tool: run the planner outside the game against real Auctionator data.
--
--   python3 -I Tools/dev/export_auctionator.py <WTF/.../SavedVariables/Auctionator.lua> /tmp/auc_plain.lua
--   lua5.1 Tools/dev/offline_test.lua /tmp/auc_plain.lua tailoring [startSkill] [tips|-] [target]
--
-- Item sell prices are not available offline, so sale values are 0 here.
local aucFile, prof, start = arg[1], arg[2] or "tailoring", tonumber(arg[3]) or 1
local root = (debug.getinfo(1, "S").source:sub(2):match("^(.*)/Tools/dev/") or ".") .. "/"

-- WoW API stubs ------------------------------------------------------------
local noop = function() end
local function stubObject()
    local scripts = {}
    return setmetatable({ scripts = scripts }, {
        __index = function(t, k)
            if k == "SetScript" then return function(_, name, fn) scripts[name] = fn end end
            if k == "GetScript" then return function(_, name) return scripts[name] end end
            return noop
        end,
    })
end
local frames = {}
function CreateFrame() local f = stubObject() table.insert(frames, f) return f end
C_Timer = { After = function(_, fn) fn() end }
C_Item = { GetItemInfo = function() return nil end, GetItemCount = function() return 0 end, RequestLoadItemDataByID = noop }
function CopyTable(t) local r = {} for k, v in pairs(t) do r[k] = type(v) == "table" and CopyTable(v) or v end return r end
function strtrim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end
function geterrorhandler() return function(e) print("ERROR: " .. tostring(e)) end end
function debugprofilestop() return os.clock() * 1000 end
function tinsert(t, v) table.insert(t, v) end
-- CP_PRELOAD=file.lua runs a file here to add more stubs (e.g. sell prices, TSM_API)
if os.getenv("CP_PRELOAD") then dofile(os.getenv("CP_PRELOAD")) end
UISpecialFrames, SlashCmdList, UIParent = {}, {}, {}

-- Auctionator stub backed by exported data ---------------------------------
dofile(aucFile)
local realm, db = next(AUCTIONATOR_PRICE_DATABASE_PLAIN)
local today = 0
for _, e in pairs(db) do if type(e) == "table" then for d in pairs(e.h or {}) do today = math.max(today, tonumber(d)) end end end
local function age(key)
    local e = db[key]
    if not e then return end
    local last
    for d in pairs(e.h or {}) do last = math.max(last or 0, tonumber(d)) end
    return last and (today - last)
end
Auctionator = {
    API = { v1 = {
        GetAuctionPriceByItemID = function(_, id) return db[tostring(id)] and db[tostring(id)].m end,
        GetAuctionAgeByItemID = function(_, id) return age(tostring(id)) end,
        GetVendorPriceByItemID = function(_, id) return AUCTIONATOR_VENDOR_PRICE_CACHE[tostring(id)] end,
    } },
    Database = {
        GetPriceHistory = function(_, key)
            local e = db[key]
            if not e then return {} end
            local days = {}
            for d in pairs(e.h) do days[#days + 1] = d end
            table.sort(days, function(a, b) return a > b end)
            local out = {}
            for _, d in ipairs(days) do out[#out + 1] = { available = e.a and e.a[d] } end
            return out
        end,
    },
}
print(("Auctionator realm %q, scan day %d"):format(realm, today))

-- Load the addon -----------------------------------------------------------
local ns = {}
for _, file in ipairs({ "Core.lua", "Data/Recipes.lua", "Data/TrainerData.lua", "Data/VendorSeed.lua", "Prices.lua", "Scan.lua", "Planner.lua", "Skin.lua", "UI.lua" }) do
    local chunk = assert(loadfile(root .. file))
    chunk("jewilUI_ProfessionLeveler", ns)
end
local onEvent = frames[1].scripts.OnEvent
onEvent(frames[1], "ADDON_LOADED", "jewilUI_ProfessionLeveler")
-- CP_OPTS="avoidGreen=false,useBags=true" overrides options
for k, v in (os.getenv("CP_OPTS") or ""):gmatch("(%w+)=(%w+)") do
    ns.db.opts[k] = (v == "true") or (v ~= "false" and tonumber(v)) or false
end

local t0 = os.clock()
local target = tonumber(arg[5]) or 300
-- CP_PLANNED="Pattern: Wild Leather Cloak;Pattern: ..." ticks recipes to obtain
for name in (os.getenv("CP_PLANNED") or ""):gmatch("[^;]+") do
    for _, rec in ipairs(ns.Data.recipes[prof]) do
        if rec.book and ns.Data.names[rec.book] == name then ns.Planned(prof)[ns.RecipeKey(rec)] = true end
    end
end
local plan = assert(ns.UI.Compute(prof, start, target))
PLAN = plan
local ms = (os.clock() - t0) * 1000
local showTips = arg[4] == "tips"
local function strip(t) return (t:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")) end
local tt = {
    AddLine = function(_, t) print("      | " .. strip(t)) end,
    AddDoubleLine = function(_, l, r) print("      | " .. strip(l) .. "  ->  " .. strip(r)) end,
}
for _, line in ipairs(ns.UI.Render(plan)) do
    local text = line.text
    if line.cols then
        local parts = {}
        for _, c in ipairs(line.cols) do parts[#parts + 1] = strip(c[1]):gsub("\n", "; ") end
        text = table.concat(parts, " | ")
    end
    print((line.check and (line.check.checked and "[x] " or "[ ] ") or "") .. strip(text))
    if showTips and line.tip then line.tip(tt) end
end
print(("planned in %.0f ms"):format(ms))
