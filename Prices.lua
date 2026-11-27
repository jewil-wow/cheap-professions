-- Prices.lua: buy prices (Auctionator AH + vendor), AH supply, and sale values.
local addonName, ns = ...

local Prices = {}
ns.Prices = Prices

local GetItemInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
local GetItemCount = (C_Item and C_Item.GetItemCount) or GetItemCount
local RequestLoad = (C_Item and C_Item.RequestLoadItemDataByID) or function() end

local API = Auctionator and Auctionator.API and Auctionator.API.v1

-- Lowest AH buyout from the latest Auctionator scan, its age in days, and the
-- quantity listed (summed across all prices, on the most recent scan day).
-- Returns nil when there is no usable AH data.
function Prices.AH(itemID)
    if not API then return end
    local ok, price = pcall(API.GetAuctionPriceByItemID, addonName, itemID)
    if not ok or not price or price <= 0 then return end
    local _, age = pcall(API.GetAuctionAgeByItemID, addonName, itemID)
    if type(age) ~= "number" then age = nil end
    if age and age > ns.db.opts.maxAgeDays then return end
    local qty
    local db = Auctionator.Database
    if db and db.GetPriceHistory then
        local okH, hist = pcall(db.GetPriceHistory, db, tostring(itemID))
        if okH and hist then
            for _, h in ipairs(hist) do -- newest first
                if h.available then qty = h.available break end
            end
        end
    end
    return price, age, qty
end

-- Vendor buy price per unit, and whether it is only our approximate seed.
function Prices.Vendor(itemID)
    if API then
        local ok, p = pcall(API.GetVendorPriceByItemID, addonName, itemID)
        if ok and p and p > 0 then return p, false end
    end
    local seed = ns.Data.vendorSeed[itemID]
    if seed then return seed, true end
end

function Prices.Bags(itemID)
    if not ns.db.opts.useBags then return 0 end
    return GetItemCount(itemID, true) or 0
end

-- Copies of an item in bags and bank, regardless of the "count bags" option.
function Prices.Owned(itemID)
    return GetItemCount(itemID, true) or 0
end

local pendingLoad = {}
local function sellPrice(itemID)
    local sell = select(11, GetItemInfo(itemID))
    if sell == nil and not pendingLoad[itemID] then
        pendingLoad[itemID] = true
        RequestLoad(itemID)
    end
    return sell
end

-- Value received per crafted item: AH price minus cut for items on your AH-sell
-- list ("ah"), otherwise the vendor sell price ("vendor"). The third value has the
-- prices behind an AH choice (kept with the plan).
function Prices.SaleValue(itemID)
    if not itemID then return 0, "none" end
    local vendor = sellPrice(itemID) or 0
    local o = ns.db.opts
    if ns.db.ahSell[itemID] then
        local p = Prices.AH(itemID)
        if p then return math.floor(p * (1 - o.ahCut)), "ah", { ah = p, vendor = vendor } end
    end
    return vendor, "vendor"
end

function Prices.ItemName(itemID)
    local name = GetItemInfo(itemID)
    if name then return name end
    if ns.Data.names[itemID] then return ns.Data.names[itemID] end
    for _, list in pairs(ns.Data.recipes) do
        for _, rec in ipairs(list) do
            if rec.i == itemID then return rec.n end
        end
    end
    return "item:" .. itemID
end

function Prices.Money(copper)
    copper = math.floor((copper or 0) + 0.5)
    local neg = copper < 0
    copper = math.abs(copper)
    local g, s, c = math.floor(copper / 10000), math.floor(copper / 100) % 100, copper % 100
    local str
    if g > 0 then
        str = string.format("%d|cffffd700g|r %02d|cffc7c7cfs|r", g, s)
    elseif s > 0 then
        str = string.format("%d|cffc7c7cfs|r %02d|cffeda55fc|r", s, c)
    else
        str = string.format("%d|cffeda55fc|r", c)
    end
    return neg and ("-" .. str) or str
end

function Prices.HasPending()
    return next(pendingLoad) ~= nil
end

-- Fires (debounced) when item data we asked for arrives, so plans can refresh sale values.
ns.On("GET_ITEM_INFO_RECEIVED", function(itemID)
    if pendingLoad[itemID] then
        pendingLoad[itemID] = nil
        if ns.UI and ns.UI.RefreshSoon then ns.UI.RefreshSoon() end
    end
end)
