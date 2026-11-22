-- Skin.lua: flat dark widgets (panel, buttons, tabs, edit boxes, checkboxes, scroll area).
-- Everything is drawn with plain colour textures, so no art files or other addons are needed.
local _, ns = ...

local S = {}
ns.Skin = S

S.ACCENT = { 0.05, 0.82, 0.62 }
S.BG = { 0.055, 0.059, 0.067, 0.96 }
S.BAR = { 0.085, 0.09, 0.1, 1 }      -- title bar
S.CTRL = { 0.11, 0.115, 0.13, 1 }    -- buttons
S.CTRL_HI = { 0.16, 0.17, 0.19, 1 }
S.INPUT = { 0.035, 0.038, 0.045, 1 }
S.EDGE = { 0.19, 0.2, 0.22, 1 }
S.GRID = { 0.22, 0.23, 0.26, 1 }     -- table cell borders
S.HEAD = { 0.1, 0.105, 0.12, 1 }     -- table header row
S.DIM = { 0.58, 0.6, 0.64 }

function S.Hex(c)
    return ("|cff%02x%02x%02x"):format(c[1] * 255, c[2] * 255, c[3] * 255)
end

local function color(t, c, a) t:SetColorTexture(c[1], c[2], c[3], a or c[4] or 1) end
S.Color = color

function S.Tex(parent, layer, c, sub)
    local t = parent:CreateTexture(nil, layer or "BACKGROUND", nil, sub)
    color(t, c)
    return t
end

-- 1px border inside the frame's edges. Returns a table with :SetColor(c).
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

function S.Panel(f)
    f.bg = S.Tex(f, "BACKGROUND", S.BG)
    f.bg:SetAllPoints()
    f.border = S.Border(f, S.EDGE)
    return f
end

function S.Label(parent, text, dim)
    local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    fs:SetText(text or "")
    if dim then fs:SetTextColor(S.DIM[1], S.DIM[2], S.DIM[3]) end
    return fs
end

-- Flat button. kind = "primary" (accent fill) or "tab" (can be selected).
function S.Button(parent, text, w, h, kind)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(w, h)
    b.bg = S.Tex(b, "BACKGROUND", kind == "primary" and S.ACCENT or S.CTRL)
    b.bg:SetAllPoints()
    b.border = S.Border(b, kind == "primary" and S.ACCENT or S.EDGE)
    b.bar = S.Tex(b, "ARTWORK", S.ACCENT) -- selected-tab underline
    b.bar:SetPoint("BOTTOMLEFT", 1, 1); b.bar:SetPoint("BOTTOMRIGHT", -1, 1); b.bar:SetHeight(2)
    b.bar:Hide()
    local fs = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    fs:SetPoint("CENTER", 0, 0)
    b:SetFontString(fs)
    b:SetText(text)
    local function paint(hover)
        if kind == "primary" then
            color(b.bg, S.ACCENT, hover and 1 or 0.82)
            fs:SetTextColor(0.02, 0.05, 0.04)
            fs:SetShadowOffset(0, 0)
            fs:SetShadowColor(0, 0, 0, 0)
        else
            color(b.bg, hover and S.CTRL_HI or S.CTRL)
            b.border:SetColor((hover or b.selected) and S.ACCENT or S.EDGE)
            if b.selected then
                fs:SetTextColor(S.ACCENT[1], S.ACCENT[2], S.ACCENT[3])
            elseif hover then
                fs:SetTextColor(1, 1, 1)
            else
                fs:SetTextColor(0.82, 0.84, 0.87)
            end
        end
    end
    b:SetScript("OnEnter", function() paint(true) end)
    b:SetScript("OnLeave", function() paint(false) end)
    b:SetScript("OnMouseDown", function() fs:SetPoint("CENTER", 0, -1) end)
    b:SetScript("OnMouseUp", function() fs:SetPoint("CENTER", 0, 0) end)
    function b:SetSelected(sel)
        self.selected = sel and true or false
        self.bar:SetShown(self.selected)
        paint(self:IsMouseOver())
    end
    paint(false)
    return b
end

-- Close button: an X drawn from two thin rotated bars (falls back to a letter).
function S.CloseButton(parent)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(20, 20)
    local parts = {}
    local t1 = b:CreateTexture(nil, "ARTWORK")
    if t1.SetRotation then
        for i, ang in ipairs({ math.pi / 4, -math.pi / 4 }) do
            local t = i == 1 and t1 or b:CreateTexture(nil, "ARTWORK")
            t:SetSize(12, 1.5)
            t:SetPoint("CENTER")
            t:SetRotation(ang)
            parts[i] = t
        end
    else
        local fs = b:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        fs:SetPoint("CENTER")
        fs:SetText("X")
        parts.fs = fs
    end
    local function paint(c)
        for _, t in ipairs(parts) do color(t, c) end
        if parts.fs then parts.fs:SetTextColor(c[1], c[2], c[3]) end
    end
    paint(S.DIM)
    b:SetScript("OnEnter", function() paint({ 1, 0.35, 0.35 }) end)
    b:SetScript("OnLeave", function() paint(S.DIM) end)
    b:SetScript("OnClick", function() parent:GetParent():Hide() end)
    return b
end

function S.EditBox(parent, w, h)
    local e = CreateFrame("EditBox", nil, parent)
    e:SetSize(w, h)
    e:SetFontObject(GameFontHighlightSmall)
    e:SetJustifyH("CENTER")
    e:SetTextInsets(4, 4, 0, 0)
    e:SetAutoFocus(false)
    e.bg = S.Tex(e, "BACKGROUND", S.INPUT)
    e.bg:SetAllPoints()
    e.border = S.Border(e, S.EDGE)
    e:SetScript("OnEditFocusGained", function(self) self.border:SetColor(S.ACCENT) self:HighlightText() end)
    e:SetScript("OnEditFocusLost", function(self) self.border:SetColor(S.EDGE) self:HighlightText(0, 0) end)
    e:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    return e
end

-- Square checkbox; the checked state shows an accent square inside.
function S.Check(parent, size)
    local c = CreateFrame("CheckButton", nil, parent)
    size = size or 14
    c:SetSize(size, size)
    c.bg = S.Tex(c, "BACKGROUND", S.INPUT)
    c.bg:SetAllPoints()
    c.border = S.Border(c, S.EDGE)
    local mark = c:CreateTexture(nil, "ARTWORK")
    color(mark, S.ACCENT)
    mark:SetPoint("TOPLEFT", 3, -3)
    mark:SetPoint("BOTTOMRIGHT", -3, 3)
    c:SetCheckedTexture(mark)
    c:HookScript("OnEnter", function(self) self.border:SetColor(S.ACCENT) end)
    c:HookScript("OnLeave", function(self) self.border:SetColor(S.EDGE) end)
    return c
end

-- Scroll area with mouse wheel and a slim draggable bar on the right.
-- Returns scroll frame and its child (set the child's height; the bar follows).
function S.Scroll(parent, width)
    local scroll = CreateFrame("ScrollFrame", nil, parent)
    local child = CreateFrame("Frame", nil, scroll)
    child:SetSize(width, 10)
    scroll:SetScrollChild(child)

    local bar = CreateFrame("Slider", nil, parent)
    bar:SetWidth(6)
    bar:SetPoint("TOPLEFT", scroll, "TOPRIGHT", 6, 0)
    bar:SetPoint("BOTTOMLEFT", scroll, "BOTTOMRIGHT", 6, 0)
    bar:SetOrientation("VERTICAL")
    bar:SetMinMaxValues(0, 0)
    bar:SetValueStep(1)
    local track = S.Tex(bar, "BACKGROUND", S.INPUT)
    track:SetAllPoints()
    local thumb = bar:CreateTexture(nil, "OVERLAY")
    color(thumb, S.GRID)
    thumb:SetSize(6, 40)
    bar:SetThumbTexture(thumb)
    bar:EnableMouse(true)
    bar:SetScript("OnEnter", function() color(thumb, S.ACCENT) end)
    bar:SetScript("OnLeave", function() color(thumb, S.GRID) end)
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
    scroll:SetScript("OnMouseWheel", function(_, delta)
        bar:SetValue(bar:GetValue() - delta * 48)
    end)
    scroll.Update = update
    function scroll:ScrollToTop() bar:SetValue(0) end
    return scroll, child
end
