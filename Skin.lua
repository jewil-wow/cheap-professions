-- Skin.lua: shadcn/ui-style widgets (dark neutral theme): rounded cards, pill buttons and
-- inputs, Geist font. Shapes are plain colour textures plus anti-aliased circle corners
-- from Media\circleN.tga (made by Tools/make_circles.py), so no other addons are needed.
local _, ns = ...

local S = {}
ns.Skin = S

local MEDIA = "Interface\\AddOns\\jewilUI_ProfessionLeveler\\Media\\"

local function hex(h, a)
    return { tonumber(h:sub(1, 2), 16) / 255, tonumber(h:sub(3, 4), 16) / 255, tonumber(h:sub(5, 6), 16) / 255, a or 1 }
end
S.hex = hex
-- shadcn "neutral" dark tokens
S.BG = hex("0a0a0a")       -- background
S.CARD = hex("171717")     -- card / popover
S.FG = hex("fafafa")       -- foreground
S.PRIMARY = hex("e5e5e5")  -- primary button
S.ON_PRIMARY = hex("171717")
S.SECONDARY = hex("262626")
S.SECONDARY_HI = hex("333333")
S.MUTED = hex("262626")    -- hover rows, active tab
S.EDGE = hex("262626")     -- border
S.INPUT = hex("1f1f1f")    -- input fill
S.INPUT_EDGE = hex("2e2e2e")
S.RING = hex("737373")     -- focus ring
S.DIM = hex("a1a1a1")      -- muted foreground
S.FAINT = hex("737373")    -- hints
S.THUMB = hex("404040")    -- scrollbar thumb, grip
S.GRID = S.EDGE
S.ACCENT = S.PRIMARY
S.HIGHLIGHT = hex("fb923c") -- orange-400 (same as the warnings): step labels, table headers

function S.Hex(c)
    return ("|cff%02x%02x%02x"):format(c[1] * 255, c[2] * 255, c[3] * 255)
end

local function color(t, c, a) t:SetColorTexture(c[1], c[2], c[3], a or c[4] or 1) end
S.Color = color

---------------------------------------------------------------------------
-- Fonts (Geist, SIL Open Font License: Media\Geist-OFL.txt)
S.FONTS = {
    regular = MEDIA .. "Geist-Regular.ttf",
    medium = MEDIA .. "Geist-Medium.ttf",
    semibold = MEDIA .. "Geist-SemiBold.ttf",
}
local fonts = {}
function S.Font(name, weight, size)
    if fonts[name] then return fonts[name] end
    local f = CreateFont("jewilUI_ProfessionLevelerFont" .. name)
    -- falls back to the game font if the file can't be loaded (e.g. WoW wasn't restarted)
    if not f:SetFont(S.FONTS[weight], size, "") then
        f:SetFont(STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF", size - 1, "")
    end
    f:SetShadowOffset(0, 0)
    f:SetTextColor(S.FG[1], S.FG[2], S.FG[3])
    fonts[name] = f
    return f
end
function S.Body() return S.Font("Body", "regular", 12) end
function S.Small() return S.Font("Small", "regular", 11) end
function S.Strong() return S.Font("Strong", "medium", 12) end
function S.ButtonFont() return S.Font("Button", "medium", 11) end
function S.TabFont() return S.Font("Tab", "medium", 15) end
function S.Heading() return S.Font("Heading", "semibold", 14) end
function S.Title() return S.Font("Title", "semibold", 20) end
function S.Overline() return S.Font("Overline", "medium", 10) end

function S.FontString(parent, font, layer)
    local fs = parent:CreateFontString(nil, layer or "OVERLAY")
    fs:SetFontObject(font or S.Body())
    return fs
end

function S.Tex(parent, layer, c, sub)
    local t = parent:CreateTexture(nil, layer or "BACKGROUND", nil, sub)
    color(t, c)
    return t
end

---------------------------------------------------------------------------
-- Rounded rectangle: four circle-quarter corners plus three plain strips, all hung off an
-- invisible anchor texture. Position it like a texture (SetPoint / SetAllPoints).
-- The box must be at least 2r tall and wide.
local CIRCLES = { 8, 16, 32, 64 }
local Round = {}
Round.__index = Round
local CORNERS = {
    { "TOPLEFT", 0, 0.5, 0, 0.5 }, { "TOPRIGHT", 0.5, 1, 0, 0.5 },
    { "BOTTOMLEFT", 0, 0.5, 0.5, 1 }, { "BOTTOMRIGHT", 0.5, 1, 0.5, 1 },
}
function S.Round(parent, layer, sub, c, r)
    local o = setmetatable({ parts = {} }, Round)
    o.anchor = parent:CreateTexture(nil, layer, nil, sub)
    o.anchor:SetColorTexture(0, 0, 0, 0)
    for i = 1, 4 do
        local t = parent:CreateTexture(nil, layer, nil, sub)
        o.parts[i] = t
    end
    for i = 5, 7 do o.parts[i] = parent:CreateTexture(nil, layer, nil, sub) end
    o:SetRadius(r)
    o:SetColor(c)
    return o
end
function Round:SetRadius(r)
    r = math.max(1, r)
    self.r = r
    local file = CIRCLES[#CIRCLES]
    for _, n in ipairs(CIRCLES) do if n / 2 >= r then file = n break end end
    local a, p = self.anchor, self.parts
    for i, c in ipairs(CORNERS) do
        local t = p[i]
        t:SetTexture(MEDIA .. "circle" .. file)
        t:SetTexCoord(c[2], c[3], c[4], c[5])
        t:SetSize(r, r)
        t:ClearAllPoints()
        t:SetPoint(c[1], a, c[1])
    end
    -- The strips reach 1px into the corners so no hairline gap opens between the pieces
    -- at fractional UI scales (the circle's edge is already solid that close to the seam).
    local o = math.min(1, r / 2)
    p[5]:ClearAllPoints() -- middle column, full height
    p[5]:SetPoint("TOPLEFT", a, "TOPLEFT", r - o, 0)
    p[5]:SetPoint("BOTTOMRIGHT", a, "BOTTOMRIGHT", -(r - o), 0)
    p[6]:ClearAllPoints() -- left strip between the corners
    p[6]:SetPoint("TOPLEFT", a, "TOPLEFT", 0, -(r - o))
    p[6]:SetPoint("BOTTOMRIGHT", a, "BOTTOMLEFT", r, r - o)
    p[7]:ClearAllPoints() -- right strip
    p[7]:SetPoint("TOPLEFT", a, "TOPRIGHT", -r, -(r - o))
    p[7]:SetPoint("BOTTOMRIGHT", a, "BOTTOMRIGHT", 0, r - o)
end
function Round:SetColor(c, alpha)
    local a = alpha or c[4] or 1
    for i = 1, 4 do self.parts[i]:SetVertexColor(c[1], c[2], c[3], a) end
    for i = 5, 7 do self.parts[i]:SetColorTexture(c[1], c[2], c[3], a) end
end
function Round:SetShown(b) for _, t in ipairs(self.parts) do t:SetShown(b) end end
function Round:Show() self:SetShown(true) end
function Round:Hide() self:SetShown(false) end
function Round:SetPoint(...) self.anchor:SetPoint(...) end
function Round:SetAllPoints(...) self.anchor:SetAllPoints(...) end
function Round:ClearAllPoints() self.anchor:ClearAllPoints() end

-- Rounded box with an optional 1px border (a slightly larger rounded rect behind the fill).
-- Fill colours should be opaque so the border doesn't show through.
local Box = {}
Box.__index = Box
function S.Box(parent, fill, edge, r, layer, sub)
    layer, sub = layer or "BACKGROUND", sub or -8
    local o = setmetatable({}, Box)
    if edge then
        o.edge = S.Round(parent, layer, sub, edge, r)
        o.fill = S.Round(parent, layer, sub + 1, fill, math.max(1, r - 1))
        o.fill:SetPoint("TOPLEFT", o.edge.anchor, "TOPLEFT", 1, -1)
        o.fill:SetPoint("BOTTOMRIGHT", o.edge.anchor, "BOTTOMRIGHT", -1, 1)
        o.outer = o.edge
    else
        o.fill = S.Round(parent, layer, sub, fill, r)
        o.outer = o.fill
    end
    return o
end
function Box:SetPoint(...) self.outer:SetPoint(...) end
function Box:SetAllPoints(...) self.outer:SetAllPoints(...) end
function Box:ClearAllPoints() self.outer:ClearAllPoints() end
function Box:SetFill(c, a) self.fill:SetColor(c, a) end
function Box:SetEdge(c, a) if self.edge then self.edge:SetColor(c, a) end end
function Box:SetShown(b) self.fill:SetShown(b) if self.edge then self.edge:SetShown(b) end end
function Box:Show() self:SetShown(true) end
function Box:Hide() self:SetShown(false) end
function Box:SetRadius(r)
    if self.edge then self.edge:SetRadius(r) self.fill:SetRadius(math.max(1, r - 1)) else self.fill:SetRadius(r) end
end

-- 1px square border inside the frame's edges (kept for simple separators).
function S.Border(f, c, layer)
    local e = {}
    for i = 1, 4 do e[i] = S.Tex(f, layer or "BORDER", c or S.EDGE) end
    e[1]:SetPoint("TOPLEFT"); e[1]:SetPoint("TOPRIGHT"); e[1]:SetHeight(1)
    e[2]:SetPoint("BOTTOMLEFT"); e[2]:SetPoint("BOTTOMRIGHT"); e[2]:SetHeight(1)
    e[3]:SetPoint("TOPLEFT"); e[3]:SetPoint("BOTTOMLEFT"); e[3]:SetWidth(1)
    e[4]:SetPoint("TOPRIGHT"); e[4]:SetPoint("BOTTOMRIGHT"); e[4]:SetWidth(1)
    function e:SetColor(c2) for i = 1, 4 do color(self[i], c2) end end
    return e
end

-- Window: rounded background card.
function S.Panel(f)
    f.box = S.Box(f, S.BG, S.EDGE, 12)
    f.box:SetAllPoints(f)
    return f
end

function S.Label(parent, text, dim)
    local fs = S.FontString(parent, S.Small())
    fs:SetText(text or "")
    local c = dim and S.DIM or S.FG
    fs:SetTextColor(c[1], c[2], c[3])
    return fs
end

---------------------------------------------------------------------------
-- Pill button. kind = nil/"secondary" (grey), "primary" (light), "outline", or "tab"
-- (tab trigger on a S.TabList; the selected one is filled). font is optional.
function S.Button(parent, text, w, h, kind, font)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(w, h)
    local r = kind == "tab" and 7 or math.floor(h / 2)
    b.box = S.Box(b, S.SECONDARY, kind == "outline" and S.EDGE or nil, r)
    b.box:SetAllPoints(b)
    local fs = S.FontString(b, font or (kind == "tab" and S.TabFont() or S.ButtonFont()))
    fs:SetPoint("CENTER", 0, 0)
    b:SetFontString(fs)
    b:SetText(text)
    local function txt(c) fs:SetTextColor(c[1], c[2], c[3]) end
    local function paint(hover)
        if kind == "primary" then
            b.box:SetFill(S.PRIMARY, hover and 0.88 or 1)
            txt(S.ON_PRIMARY)
        elseif kind == "tab" then
            b.box:SetShown(b.selected and true or false)
            b.box:SetFill(S.MUTED)
            txt((b.selected or hover) and S.FG or S.DIM)
        elseif kind == "outline" then
            b.box:SetFill(hover and S.SECONDARY or S.BG)
            txt(S.FG)
        else
            b.box:SetFill(hover and S.SECONDARY_HI or S.SECONDARY)
            txt(S.FG)
        end
    end
    b:SetScript("OnEnter", function() paint(true) end)
    b:SetScript("OnLeave", function() paint(false) end)
    function b:SetSelected(sel)
        self.selected = sel and true or false
        paint(self:IsMouseOver())
    end
    paint(false)
    return b
end

-- Rounded strip the tab triggers sit on (shadcn TabsList).
function S.TabList(parent)
    local f = CreateFrame("Frame", nil, parent)
    f.box = S.Box(f, S.CARD, S.EDGE, 10)
    f.box:SetAllPoints(f)
    return f
end

-- Round ghost icon button with an X drawn from two thin rotated bars.
function S.CloseButton(parent)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(24, 24)
    local hov = S.Round(b, "BACKGROUND", 0, S.MUTED, 12)
    hov:SetAllPoints(b)
    hov:Hide()
    local parts = {}
    local t1 = b:CreateTexture(nil, "ARTWORK")
    if t1.SetRotation then
        for i, ang in ipairs({ math.pi / 4, -math.pi / 4 }) do
            local t = i == 1 and t1 or b:CreateTexture(nil, "ARTWORK")
            t:SetSize(11, 1.5)
            t:SetPoint("CENTER")
            t:SetRotation(ang)
            parts[i] = t
        end
    else
        local fs = S.FontString(b, S.Body())
        fs:SetPoint("CENTER")
        fs:SetText("X")
        parts.fs = fs
    end
    local function paint(c)
        for _, t in ipairs(parts) do color(t, c) end
        if parts.fs then parts.fs:SetTextColor(c[1], c[2], c[3]) end
    end
    paint(S.DIM)
    b:SetScript("OnEnter", function() hov:Show() paint(S.FG) end)
    b:SetScript("OnLeave", function() hov:Hide() paint(S.DIM) end)
    b:SetScript("OnClick", function() parent:GetParent():Hide() end)
    return b
end

-- Pill input.
function S.EditBox(parent, w, h)
    local e = CreateFrame("EditBox", nil, parent)
    e:SetSize(w, h)
    e:SetFontObject(S.Body())
    e:SetJustifyH("CENTER")
    e:SetTextInsets(8, 8, 0, 0)
    e:SetAutoFocus(false)
    e.box = S.Box(e, S.INPUT, S.INPUT_EDGE, math.floor(h / 2))
    e.box:SetAllPoints(e)
    e:SetScript("OnEditFocusGained", function(self) self.box:SetEdge(S.RING) self:HighlightText() end)
    e:SetScript("OnEditFocusLost", function(self) self.box:SetEdge(S.INPUT_EDGE) self:HighlightText(0, 0) end)
    e:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    return e
end

-- Checkbox: rounded square; checked fills it light with a dark tick.
function S.Check(parent, size)
    local c = CreateFrame("CheckButton", nil, parent)
    size = size or 14
    c:SetSize(size, size)
    c.box = S.Box(c, S.INPUT, S.THUMB, 4)
    c.box:SetAllPoints(c)
    -- tick: short stroke down-right, long stroke up-right (14px design, scaled)
    local k = size / 14
    local tick = {}
    local probe = c:CreateTexture(nil, "OVERLAY")
    if probe.SetRotation then
        for i, seg in ipairs({ { 4.2, -2.3, -1.6, -math.pi / 4 }, { 7.8, 1.2, 0.1, 0.93 } }) do
            local t = i == 1 and probe or c:CreateTexture(nil, "OVERLAY")
            color(t, S.ON_PRIMARY)
            t:SetSize(seg[1] * k, 1.6 * k)
            t:SetPoint("CENTER", seg[2] * k, seg[3] * k)
            t:SetRotation(seg[4])
            tick[i] = t
        end
    end
    local hover = false
    local function sync()
        local on = c:GetChecked() and true or false
        for _, t in ipairs(tick) do t:SetShown(on) end
        c.box:SetFill(on and S.PRIMARY or S.INPUT)
        c.box:SetEdge(on and S.PRIMARY or (hover and S.RING or S.THUMB))
    end
    local set = c.SetChecked
    function c:SetChecked(v) set(self, v) sync() end
    c:HookScript("PostClick", sync) -- callers replace OnClick, so sync after it
    c:HookScript("OnEnter", function() hover = true sync() end)
    c:HookScript("OnLeave", function() hover = false sync() end)
    sync()
    return c
end

-- Scroll area with mouse wheel, a slim draggable bar on the right, and zoom.
-- Returns the scroll frame and the content frame to put rows in. The content is drawn
-- at the zoom scale inside an unscaled holder, so scrolling works in screen units.
-- After changing the content's height call scroll:Sync(); for the view width, SetViewWidth.
function S.Scroll(parent, width)
    local scroll = CreateFrame("ScrollFrame", nil, parent)
    local child = CreateFrame("Frame", nil, scroll) -- holder (scroll child, unscaled)
    child:SetSize(width, 10)
    scroll:SetScrollChild(child)
    local content = CreateFrame("Frame", nil, child)
    content:SetPoint("TOPLEFT")
    content:SetSize(width, 10)
    local zoom, viewW = 1, width

    local bar = CreateFrame("Slider", nil, parent)
    bar:SetWidth(6)
    bar:SetPoint("TOPLEFT", scroll, "TOPRIGHT", 6, 0)
    bar:SetPoint("BOTTOMLEFT", scroll, "BOTTOMRIGHT", 6, 0)
    bar:SetOrientation("VERTICAL")
    bar:SetMinMaxValues(0, 0)
    bar:SetValueStep(1)
    local thumb = bar:CreateTexture(nil, "OVERLAY")
    thumb:SetColorTexture(0, 0, 0, 0) -- invisible; a pill is drawn over it
    thumb:SetSize(6, 40)
    bar:SetThumbTexture(thumb)
    local pill = S.Round(bar, "OVERLAY", 1, S.THUMB, 3)
    pill:SetAllPoints(thumb)
    bar:EnableMouse(true)
    bar:SetScript("OnEnter", function() pill:SetColor(S.FAINT) end)
    bar:SetScript("OnLeave", function() pill:SetColor(S.THUMB) end)
    bar:SetScript("OnValueChanged", function(_, v) scroll:SetVerticalScroll(v) end)

    local function update()
        local range = math.max(0, child:GetHeight() - scroll:GetHeight())
        local view = scroll:GetHeight()
        bar:SetMinMaxValues(0, range)
        if bar:GetValue() > range then bar:SetValue(range) end
        thumb:SetHeight(math.max(24, view * view / math.max(1, view + range)))
        bar:SetShown(range > 0)
    end
    scroll:SetScript("OnScrollRangeChanged", update)
    scroll:SetScript("OnSizeChanged", update)
    scroll:EnableMouseWheel(true)
    scroll:SetScript("OnMouseWheel", function(self, delta)
        if IsControlKeyDown() and self.OnZoomWheel then return self.OnZoomWheel(delta) end
        bar:SetValue(bar:GetValue() - delta * 48)
    end)
    scroll.Update = update
    function scroll:ScrollToTop() bar:SetValue(0) end
    function scroll:Sync()
        child:SetHeight(math.max(1, content:GetHeight() * zoom))
        update()
    end
    function scroll:SetViewWidth(w)
        viewW = w
        child:SetWidth(w)
        content:SetWidth(w / zoom)
    end
    -- keeps the same part of the content at the top of the view
    function scroll:SetZoom(z)
        local top = bar:GetValue() / zoom
        zoom = z
        content:SetScale(z)
        self:SetViewWidth(viewW)
        self:Sync()
        bar:SetValue(math.min(top * z, select(2, bar:GetMinMaxValues())))
    end
    function scroll:GetZoom() return zoom end
    return scroll, content
end
