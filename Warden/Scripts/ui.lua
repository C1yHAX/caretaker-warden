--[[
    ui.lua - a small widget toolkit that builds the Warden window out of real UMG
    widgets at runtime.

    How it is put together
    ----------------------
    Layout widgets (Border, VerticalBox, ScrollBox, TextBlock, EditableText, ...) are
    plain engine classes, created with GameplayStatics:SpawnObject (the engine's own
    "Construct Object from Class") with the host widget's WidgetTree as outer.

    SpawnObject avoids depending on UE4SS's private construction-parameter layout.
    The original crash log does NOT prove StaticConstructObject caused the exit.

    UE4SS 527a483b uses a fixed 0x200-byte UFunction parameter buffer. Button:SetStyle
    needs 0x390 bytes and can corrupt memory even inside pcall. Never call it here.
    Write large structs directly into their existing UObject property instead; audit
    the full parameter block (including out/return values) before adding new calls.

    Clickable things are instances of the game's own BP_VoyageCheat_MenuButton_Widget.
    That blueprint is just a Button with a bound click event, and the bound event is a
    real UFunction, so RegisterHook can see every click. Its click logic only fires its
    own OnClicked dispatcher, which nothing of ours binds, so a click has no side effect
    in the game. The look is replaced completely: our own button style, our own content.
    One hook serves every button; the clicked widget's address picks the handler.

    The host is kept in the viewport for the whole session and only collapsed when the
    menu closes. That keeps every widget referenced (Lua references do not stop garbage
    collection) and makes opening the menu instant.

    Handlers never run inside the hook: they are queued with ExecuteInGameThread, so a
    handler may load assets or rebuild lists without doing it in the middle of Slate's
    input processing.
--]]

local core = require("core")
local T = require("theme")

local M = {}

local C = T.color
local F = T.font

local CLASSES = {
    Border         = "/Script/UMG.Border",
    VerticalBox    = "/Script/UMG.VerticalBox",
    HorizontalBox  = "/Script/UMG.HorizontalBox",
    ScrollBox      = "/Script/UMG.ScrollBox",
    TextBlock      = "/Script/UMG.TextBlock",
    EditableText   = "/Script/UMG.EditableText",
    SizeBox        = "/Script/UMG.SizeBox",
    Overlay        = "/Script/UMG.Overlay",
    CanvasPanel    = "/Script/UMG.CanvasPanel",
    WidgetSwitcher = "/Script/UMG.WidgetSwitcher",
    Spacer         = "/Script/UMG.Spacer",
    Image          = "/Script/UMG.Image",
    UniformGrid    = "/Script/UMG.UniformGridPanel",
    Button         = "/Script/UMG.Button",
}

local MENU_BUTTON = "/Game/UI/Game/HUD/BP_VoyageCheat_MenuButton_Widget.BP_VoyageCheat_MenuButton_Widget_C"
local CLICK_EVENT = MENU_BUTTON ..
    ":BndEvt__BP_VoyageCheat_MenuButton_Widget_Button_K2Node_ComponentBoundEvent_0_OnButtonClickedEvent__DelegateSignature"

-- Written into the host's Text property so a window left behind by an earlier load of
-- the mod can be found again. SpawnObject cannot name objects.
local HOST_MARK = "WardenHost"

-- ESlateVisibility
local VISIBLE, COLLAPSED, HIDDEN, SELF_HIT_TEST_INVISIBLE = 0, 1, 2, 4
M.VISIBLE, M.COLLAPSED, M.HIDDEN = VISIBLE, COLLAPSED, HIDDEN
-- EHorizontalAlignment / EVerticalAlignment
local FILL, LEFT, CENTER, RIGHT = 0, 1, 2, 3
M.FILL, M.LEFT, M.CENTER, M.RIGHT = FILL, LEFT, CENTER, RIGHT
M.TOP, M.BOTTOM = 1, 3

local cls = {}
local menuButtonClass = nil
local fontObject = nil
local wbl = nil

local host = nil      -- the UserWidget in the viewport
local tree = nil      -- host.WidgetTree, outer of every constructed widget
local hostPc = nil    -- address of the PlayerController the host was built for
local counter = 0

local handlers = {}   -- widget address -> function
local hookRegistered = false
local textState, visibleState, styleState = {}, {}, {}
M.metrics = { buildMs=0, refreshMs=0, refreshMaxMs=0, widgets=0 }

M.isOpen = false
M.pages = {}
M.activePage = 0

------------------------------------------------------------------------------------------
-- Structs
------------------------------------------------------------------------------------------

local function margin(p)
    if p == nil then
        return { Left = 0, Top = 0, Right = 0, Bottom = 0 }
    end
    if type(p) == "number" then
        return { Left = p, Top = p, Right = p, Bottom = p }
    end
    if #p == 2 then
        return { Left = p[1], Top = p[2], Right = p[1], Bottom = p[2] }
    end
    return { Left = p[1] or 0, Top = p[2] or 0, Right = p[3] or 0, Bottom = p[4] or 0 }
end
M.margin = margin

local function slateColor(c)
    return { SpecifiedColor = c, ColorUseRule = 0 }
end

-- A rounded, flat brush. No texture: Slate fills it with the tint.
local function brush(fill, radius, outline, width)
    local r = radius or 0
    return {
        TintColor = slateColor(fill),
        DrawAs = (r > 0 or (width or 0) > 0) and 4 or 1,  -- RoundedBox, else Box
        Tiling = 0,
        Mirroring = 0,
        ImageType = 0,
        ImageSize = { X = 32, Y = 32 },
        Margin = margin(0),
        OutlineSettings = {
            CornerRadii = { X = r, Y = r, Z = r, W = r },
            Color = slateColor(outline or fill),
            Width = width or 0,
            RoundingType = 0,
            bUseBrushTransparency = false,
        },
    }
end
M.brush = brush

local function buttonStyle(normal, hover, press, radius, outline, hoverOutline)
    local w = outline and 1 or 0
    return {
        Normal = brush(normal, radius, outline or normal, w),
        Hovered = brush(hover, radius, hoverOutline or outline or hover, w),
        Pressed = brush(press, radius, hoverOutline or outline or press, w),
        Disabled = brush(normal, radius, outline or normal, w),
        NormalForeground = slateColor(C.text),
        HoveredForeground = slateColor(C.text),
        PressedForeground = slateColor(C.text),
        DisabledForeground = slateColor(C.muted),
        NormalPadding = margin(0),
        PressedPadding = margin(0),
    }
end

local R = T.metric.controlRadius
local STYLES = {
    row     = buttonStyle(C.clear, C.rowHover, C.rowPress, R),
    action  = buttonStyle(C.control, C.controlHover, C.controlPress, R, C.controlBorder, C.accent),
    primary = buttonStyle(C.accent, C.accentHover, C.accentPress, R),
    chip    = buttonStyle(C.control, C.controlHover, C.controlPress, R, C.controlBorder),
    chipOn  = buttonStyle(C.accentDim, C.accentDim, C.accentDim, R, C.accent),
    tab     = buttonStyle(C.clear, C.rowHover, C.rowPress, R),
    ghost   = buttonStyle(C.clear, C.rowHover, C.rowPress, R, C.controlBorder, C.accent),
    danger  = buttonStyle(C.control, C.controlHover, C.controlPress, R, C.controlBorder, C.bad),
}

local function fontInfo(size, bold)
    return {
        FontObject = fontObject,
        TypefaceFontName = FName(bold and "Bold" or "Regular"),
        Size = size,
        LetterSpacing = 0,
        SkewAmount = 0.0,
        bForceMonospaced = false,
        bMaterialIsStencil = false,
        MonospacedWidth = 1.0,
        OutlineSettings = {
            OutlineSize = 0,
            bMiteredCorners = false,
            bSeparateFillAlpha = false,
            bApplyOutlineToDropShadows = false,
            OutlineColor = C.clear,
        },
    }
end

------------------------------------------------------------------------------------------
-- Construction
------------------------------------------------------------------------------------------

-- While M.trace is on, every native call writes a [step] line BEFORE it runs. A native
-- fault leaves no Lua error, so the last step line in UE4SS.log names the exact call.
M.trace = false
M.traceBuilds = false   -- trace page builds and opening too (set by main.lua)

local function step(what)
    if M.trace then
        core.log("[step] " .. what)
    end
end
M.step = step

local failedOnce = {}
local function try(what, fn)
    step(what)
    local ok, err = pcall(fn)
    if not ok and not failedOnce[what] then
        failedOnce[what] = true
        core.log("ui: " .. what .. " failed: " .. tostring(err))
    end
    return ok
end

local spawner = nil

local function spawn(c, kind)
    step("SpawnObject " .. kind)
    local w = spawner:SpawnObject(c, tree)
    if not core.isValid(w) then
        error("could not construct " .. kind)
    end
    return w
end

function M.new(kind)
    counter = counter + 1
    local c = cls[kind]
    if c == nil then
        error("widget class not resolved: " .. kind)
    end
    return spawn(c, kind)
end

-- Adds child to a panel and configures the slot.
--   pad    margin (number, {h, v} or {l, t, r, b})
--   fill   true or a weight: fill the free space along the panel's axis
--   h, v   alignment (ui.FILL/LEFT/CENTER/RIGHT, ui.TOP/BOTTOM)
function M.add(parent, child, opts)
    step("AddChild")
    local slot = parent:AddChild(child)
    if opts ~= nil and slot ~= nil then
        if opts.pad ~= nil then
            try("slot padding", function() slot:SetPadding(margin(opts.pad)) end)
        end
        if opts.fill ~= nil then
            local weight = opts.fill == true and 1.0 or opts.fill
            try("slot size", function() slot:SetSize({ Value = weight, SizeRule = 1 }) end)
        end
        if opts.h ~= nil then
            try("slot halign", function() slot:SetHorizontalAlignment(opts.h) end)
        end
        if opts.v ~= nil then
            try("slot valign", function() slot:SetVerticalAlignment(opts.v) end)
        end
    end
    return slot
end

function M.vbox()
    return M.new("VerticalBox")
end

function M.hbox()
    return M.new("HorizontalBox")
end

function M.text(s, size, color, bold, justify)
    local t = M.new("TextBlock")
    try("text font", function() t:SetFont(fontInfo(size or F.label, bold)) end)
    try("text color", function() t:SetColorAndOpacity(slateColor(color or C.text)) end)
    try("text set", function() t:SetText(core.text(s or "")) end)
    if justify ~= nil then
        try("text justify", function() t:SetJustification(justify) end)
    end
    return t
end

-- A wrapping block of small secondary text.
function M.paragraph(s, color)
    local t = M.text(s, F.small, color or C.text2)
    try("paragraph wrap", function() t:SetAutoWrapText(true) end)
    return t
end

-- Changes text and, optionally, colour of a TextBlock made by ui.text.
function M.setText(t, s, color)
    local key=core.address(t)
    local last=textState[key] or {}
    s=tostring(s or "")
    if last.text~=s then
        try("setText", function() t:SetText(core.text(s)) end)
        last.text=s
    end
    if color ~= nil and last.color~=color then
        try("setText color", function() t:SetColorAndOpacity(slateColor(color)) end)
        last.color=color
    end
    if key then textState[key]=last end
end

-- If this UE4SS build cannot pass a whole FSlateBrush from a table, borders fall back
-- to tinting the default brush: square corners, but the right colours.
local brushWorks = true

local function paintBorder(b, fill, radius, outline)
    if brushWorks then
        step("SetBrush")
        local ok = pcall(function() b:SetBrush(brush(fill, radius, outline, outline and 1 or 0)) end)
        if ok then
            try("border color", function() b:SetBrushColor(C.white) end)
            return
        end
        brushWorks = false
        core.log("ui: SetBrush from a table is not supported here - using flat colours")
    end
    try("border tint", function() b:SetBrushColor(fill) end)
end

function M.border(fill, radius, outline, pad)
    local b = M.new("Border")
    paintBorder(b, fill, radius, outline)
    try("border padding", function() b:SetPadding(margin(pad or 0)) end)
    return b
end

function M.setBorder(b, fill, radius, outline)
    paintBorder(b, fill, radius, outline)
end

-- Puts content into a Border/SizeBox/Button and aligns it.
function M.content(parent, child, h, v)
    step("SetContent")
    local slot = parent:SetContent(child)
    if slot ~= nil then
        try("content halign", function() slot:SetHorizontalAlignment(h or FILL) end)
        try("content valign", function() slot:SetVerticalAlignment(v or FILL) end)
    end
    return slot
end

function M.sizeBox(w, h, child)
    local s = M.new("SizeBox")
    if w ~= nil then
        try("size width", function() s:SetWidthOverride(w) end)
    end
    if h ~= nil then
        try("size height", function() s:SetHeightOverride(h) end)
    end
    if child ~= nil then
        M.content(s, child)
    end
    return s
end

function M.spacer()
    return M.new("Spacer")
end

function M.setVisible(w, on, hidden)
    local key=core.address(w)
    local value=on and VISIBLE or (hidden and HIDDEN or COLLAPSED)
    if key and visibleState[key]==value then return end
    try("visibility", function() w:SetVisibility(value) end)
    if key then visibleState[key]=value end
end

function M.image(size)
    local img = M.new("Image")
    local box = M.sizeBox(size, size, img)
    return box, img
end

function M.setImage(img, texture)
    if texture ~= nil and core.isValid(texture) then
        local ok = pcall(function() img:SetBrushFromTexture(texture, false) end)
        if ok then
            pcall(function() img:SetVisibility(VISIBLE) end)
            return true
        end
    end
    pcall(function() img:SetVisibility(HIDDEN) end)
    return false
end

------------------------------------------------------------------------------------------
-- Clicks
------------------------------------------------------------------------------------------

local function ensureHook()
    if hookRegistered then
        return true
    end
    local ok, err = pcall(RegisterHook, CLICK_EVENT, function(context)
        local widget = context
        pcall(function() widget = context:get() end)
        local key = core.address(widget)
        local handler = key and handlers[key]
        if handler ~= nil then
            ExecuteInGameThread(function()
                core.safe("click handler", handler)
            end)
        end
    end)
    if not ok then
        core.log("could not hook the button click event: " .. tostring(err))
        return false
    end
    hookRegistered = true
    return true
end

function M.onClick(widget, fn)
    local key = core.address(widget)
    if key ~= nil then
        handlers[key] = fn
    end
end

-- A clickable widget in one of the STYLES. Returns the widget; its content is set with
-- ui.setButtonContent.
function M.clickable(kind, onClick)
    local pc = core.pc()
    step("Create menu button")
    local w = wbl:Create(pc, menuButtonClass, pc)
    if not core.isValid(w) then
        error("could not create a menu button")
    end
    -- These widgets have no animations or Tick logic; click delegates still work.
    try("button tick",function() w.TickFrequency=0 end)
    M.style(w, kind or "row")
    try("button focus", function() w.Button.IsFocusable = false end)
    if onClick ~= nil then
        M.onClick(w, onClick)
    end
    return w
end

-- The flat colour each style falls back to when direct property assignment fails.
local STYLE_FALLBACK = {
    row = C.clear, tab = C.clear, ghost = C.clear,
    action = C.control, chip = C.control, danger = C.control,
    primary = C.accent, chipOn = C.accentDim,
}
local styleWorks = true

function M.style(w, kind)
    local key=core.address(w)
    if key and styleState[key]==kind then return end
    if key then styleState[key]=kind end
    local style = STYLES[kind] or STYLES.row
    if styleWorks then
        step("WidgetStyle property " .. tostring(kind))
        -- In-place reflected property write: no oversized UFunction parameter block.
        -- Existing non-reflected brush handles remain owned by the Button.
        local ok = pcall(function() w.Button.WidgetStyle = style end)
        if ok then
            try("button bg", function() w.Button:SetBackgroundColor(C.white) end)
            return
        end
        styleWorks = false
        core.log("ui: WidgetStyle property assignment failed - using flat colours")
    end
    try("button tint", function() w.Button:SetBackgroundColor(STYLE_FALLBACK[kind] or C.control) end)
end

function M.setButtonContent(w, child, pad, h)
    step("Button SetContent")
    local slot = w.Button:SetContent(child)
    if slot ~= nil then
        try("button content pad", function() slot:SetPadding(margin(pad or { 10, 5 })) end)
        try("button content h", function() slot:SetHorizontalAlignment(h or FILL) end)
        try("button content v", function() slot:SetVerticalAlignment(CENTER) end)
    end
end

------------------------------------------------------------------------------------------
-- Composite controls
------------------------------------------------------------------------------------------

-- A pill switch. Returns { widget, set(on) }.
function M.switch()
    local box = M.sizeBox(28, 15)
    local overlay = M.new("Overlay")
    M.content(box, overlay)
    local track = M.border(C.control, 7.5, C.controlBorder)
    M.add(overlay, track, { h = FILL, v = FILL })
    local knob = M.border(C.text2, 5.5)
    local knobBox = M.sizeBox(11, 11, knob)
    local knobSlot = M.add(overlay, knobBox, { pad = { 2, 0 }, h = LEFT, v = CENTER })
    local state = nil
    local sw = { widget = box }
    function sw.set(on)
        on = on and true or false
        if state == on then
            return
        end
        state = on
        M.setBorder(track, on and C.accent or C.control, 7.5, on and C.accent or C.controlBorder)
        M.setBorder(knob, on and C.accentInk or C.text2, 5.5)
        try("knob align", function() knobSlot:SetHorizontalAlignment(on and RIGHT or LEFT) end)
    end
    sw.set(false)
    return sw
end

-- A button with a centred caption. kind: "action", "primary", "chip", "danger", "ghost".
function M.button(parent, caption, kind, onClick, opts)
    local w = M.clickable(kind or "action", onClick and function()
        core.log("Aktion: "..caption)
        onClick()
    end)
    local color = (kind == "primary") and C.accentInk or C.text
    local label = M.text(caption, (opts and opts.size) or F.label, color, true, 1)
    M.setButtonContent(w, label, (opts and opts.pad) or { 10, 6 }, CENTER)
    if parent ~= nil then
        M.add(parent, w, opts and opts.slot or { pad = { 0, 2 } })
    end
    return w, label
end

-- A grid of equal buttons, `columns` wide. items: { {caption, fn [, kind]}, ... }
function M.buttonGrid(parent, columns, items, kind)
    local grid = M.new("UniformGrid")
    try("grid padding", function() grid:SetSlotPadding(margin({ 2, 2 })) end)
    local buttons = {}
    for i, item in ipairs(items) do
        local w = M.button(nil, item[1], item[3] or kind or "chip", item[2], { pad = { 6, 5 } })
        local row = (i - 1) // columns
        local col = (i - 1) % columns
        local slot = grid:AddChildToUniformGrid(w, row, col)
        if slot ~= nil then
            try("grid slot h", function() slot:SetHorizontalAlignment(FILL) end)
            try("grid slot v", function() slot:SetVerticalAlignment(FILL) end)
        end
        buttons[#buttons + 1] = w
    end
    M.add(parent, grid, { pad = { 0, 2 } })
    return grid, buttons
end

-- A card: rounded panel with a section title. Returns the inner vertical box.
function M.card(parent, title, subtitle)
    local panel = M.border(C.panel, T.metric.panelRadius, C.panelBorder, T.metric.cardPadding)
    local body = M.vbox()
    M.content(panel, body)
    if title ~= nil then
        local head = M.hbox()
        local dot = M.sizeBox(5, 5, M.border(C.accent, 2.5))
        M.add(head, dot, { v = CENTER, pad = { 0, 0, 7, 0 } })
        M.add(head, M.text(string.upper(title), F.section, C.section, true), { v = CENTER, fill = true })
        if subtitle ~= nil then
            M.add(head, M.text(subtitle, F.small, C.muted), { v = CENTER })
        end
        M.add(body, head, { pad = { 0, 0, 0, 7 } })
    end
    M.add(parent, panel, { pad = { 0, 0, 0, T.metric.gutter } })
    return body
end

-- Label left, switch right. get() -> bool, set(bool).
function M.toggleRow(page, parent, label, get, set, note)
    local w = M.clickable("row")
    local hb = M.hbox()
    local labels = M.vbox()
    M.add(labels, M.text(label, F.label, C.text))
    if note ~= nil then
        M.add(labels, M.text(note, F.small, C.muted))
    end
    M.add(hb, labels, { fill = true, v = CENTER })
    local sw = M.switch()
    M.add(hb, sw.widget, { v = CENTER, pad = { 8, 0, 0, 0 } })
    M.setButtonContent(w, hb, { 8, 5 })
    M.add(parent, w, { pad = { 0, 1 } })
    local row = {}
    function row.refresh()
        local ok, on = pcall(get)
        sw.set(ok and on)
    end
    M.onClick(w, function()
        local ok, on = pcall(get)
        core.log("Schalter: "..label.." -> "..((ok and on) and "Aus" or "Ein"))
        set(not (ok and on))
        row.refresh()
    end)
    row.refresh()
    M.addRefresher(page, row.refresh)
    return row
end

-- Label left, value right, refreshed while the page is visible.
function M.infoRow(page, parent, label, valueFn)
    local hb = M.hbox()
    M.add(hb, M.text(label, F.label, C.text2), { fill = true, v = CENTER })
    local value = M.text("-", F.value, C.text, true, 2)
    M.add(hb, value, { v = CENTER })
    M.add(parent, hb, { pad = { 8, 3 } })
    local last = nil
    local function refresh()
        local ok, v = pcall(valueFn)
        local s = ok and tostring(v or "-") or "?"
        if s ~= last then
            last = s
            M.setText(value, s)
        end
    end
    refresh()
    M.addRefresher(page, refresh)
    return refresh
end

-- Label, then [-] value [+]. opts: values (list), index(), set(i), format(v).
function M.stepperRow(page, parent, label, opts)
    local hb = M.hbox()
    local labels = M.vbox()
    M.add(labels, M.text(label, F.label, C.text))
    if opts.note ~= nil then
        M.add(labels, M.text(opts.note, F.small, C.muted))
    end
    M.add(hb, labels, { fill = true, v = CENTER, pad = { 8, 0, 6, 0 } })
    local value = M.text("", F.value, C.accent, true, 1)
    local function step(delta)
        local n = #opts.values
        local i = opts.index() + delta
        if opts.wrap then
            i = ((i - 1) % n) + 1
        else
            i = math.max(1, math.min(n, i))
        end
        opts.set(i)
        core.log("Einstellung: "..label.." -> "..tostring(opts.format and opts.format(opts.values[i]) or opts.values[i]))
    end
    local minus = M.button(nil, "\u{2039}", "chip", function() step(-1) end, { pad = { 7, 3 } })
    M.add(hb, minus, { v = CENTER })
    M.add(hb, M.sizeBox(opts.width or 78, nil, value), { v = CENTER, pad = { 4, 0 } })
    local plus = M.button(nil, "\u{203A}", "chip", function() step(1) end, { pad = { 7, 3 } })
    M.add(hb, plus, { v = CENTER })
    M.add(parent, hb, { pad = { 0, 3 } })
    local last = nil
    local function refresh()
        local ok, i = pcall(opts.index)
        local v = ok and opts.values[i] or nil
        local s = v ~= nil and (opts.format and opts.format(v) or tostring(v)) or "-"
        if s ~= last then
            last = s
            M.setText(value, s)
        end
    end
    local origSet = opts.set
    opts.set = function(i)
        origSet(i)
        refresh()
    end
    refresh()
    M.addRefresher(page, refresh)
    return refresh
end

-- A row of segment buttons; one is active. Returns { set(i) }.
function M.segmented(parent, captions, onSelect, columns)
    local seg = {}
    local buttons
    local items = {}
    for i, caption in ipairs(captions) do
        items[#items + 1] = { caption, function() seg.set(i) onSelect(i) end }
    end
    local _, made = M.buttonGrid(parent, columns or #captions, items, "chip")
    buttons = made
    function seg.set(i)
        for j, b in ipairs(buttons) do
            M.style(b, j == i and "chipOn" or "chip")
        end
    end
    return seg
end

-- A search field. Returns { widget, get() }.
function M.searchBox(parent, hint)
    local frame = M.border(C.control, R, C.controlBorder, { 9, 5 })
    local hb = M.hbox()
    M.content(frame, hb)
    M.add(hb, M.text("\u{2315}", F.label, C.text2), { v = CENTER, pad = { 0, 0, 6, 0 } })
    local field = M.new("EditableText")
    try("search font", function() field:SetFont(fontInfo(F.label, false)) end)
    try("search hint", function() field:SetHintText(core.text(hint or "Suchen ...")) end)
    try("search color", function() field.WidgetStyle.ColorAndOpacity = slateColor(C.text) end)
    M.add(hb, field, { fill = true, v = CENTER })
    M.add(parent, frame, { pad = { 0, 2, 0, 6 } })
    local box = { widget = frame, field = field }
    function box.get()
        local ok, s = pcall(function() return core.str(field:GetText()) end)
        return ok and s or ""
    end
    function box.clear()
        try("search clear", function() field:SetText(core.text("")) end)
    end
    return box
end

--[[ A fixed pool of list rows.

    Building widgets is the slow part, so lists never create rows on the fly: a pool is
    made once and rows are filled or collapsed. items are tables with
        name, meta (right-hand text), icon (Texture2D or nil), onClick(item)
--]]
function M.listPool(parent, size, withIcons)
    local pool = { rows = {} }
    for i = 1, size do
        local w = M.clickable("row")
        local hb = M.hbox()
        local img = nil
        if withIcons then
            local box
            box, img = M.image(18)
            M.add(hb, box, { v = CENTER, pad = { 0, 0, 8, 0 } })
        end
        local name = M.text("", F.label, C.text)
        try("list clip", function() name:SetTextOverflowPolicy(1) end)   -- Ellipsis
        M.add(hb, name, { fill = true, v = CENTER })
        local meta = M.text("", F.small, C.text2, false, 2)
        M.add(hb, meta, { v = CENTER, pad = { 8, 0, 0, 0 } })
        M.setButtonContent(w, hb, { 8, 4 })
        M.add(parent, w, { pad = { 0, 1 } })
        local row = { widget = w, name = name, meta = meta, img = img, item = nil }
        M.onClick(w, function()
            if row.item ~= nil and row.item.onClick ~= nil then
                core.log("Auswahl: "..tostring(row.item.name or "Eintrag"))
                row.item.onClick(row.item)
            end
        end)
        M.setVisible(w, false)
        pool.rows[i] = row
    end
    function pool.set(items)
        for i, row in ipairs(pool.rows) do
            local item = items[i]
            row.item = item
            if item ~= nil then
                M.setText(row.name, item.name or "?", item.color or C.text)
                M.setText(row.meta, item.meta or "")
                if row.img ~= nil then
                    M.setImage(row.img, item.icon)
                end
                M.setVisible(row.widget, true)
            else
                M.setVisible(row.widget, false)
            end
        end
    end
    return pool
end

------------------------------------------------------------------------------------------
-- Pages
------------------------------------------------------------------------------------------

function M.addRefresher(page, fn)
    if page ~= nil then
        page.refreshers[#page.refreshers + 1] = fn
    end
end

-- A tab page with two columns inside a scroll box. Returns the page object with
-- page.left and page.right (vertical boxes) and page.root (the scroll box).
function M.newPage(title, columns)
    local scroll = M.new("ScrollBox")
    try("scroll thickness", function() scroll:SetScrollbarThickness({ X = 4, Y = 4 }) end)
    try("scroll padding", function() scroll:SetScrollBarPadding(margin({ 2, 0 })) end)
    local cols = M.hbox()
    M.add(scroll, cols, { pad = { 16, 14, 16, 4 } })
    -- Do not retain a per-page Slate paint/hit-test cache across host collapse or
    -- WidgetSwitcher transitions. In this game build static pages reappeared behind
    -- the window background and lost clicks, while frequently updated pages stayed
    -- usable. Keep widgets and Lua value caches, but let Slate paint the live tree.
    local page = { title = title, root = scroll, refreshers = {}, onShow = nil }
    if columns == 1 then
        page.left = M.vbox()
        M.add(cols, page.left, { fill = true })
    else
        page.left = M.vbox()
        page.right = M.vbox()
        M.add(cols, page.left, { fill = true, pad = { 0, 0, T.metric.gutter / 2, 0 } })
        M.add(cols, page.right, { fill = true, pad = { T.metric.gutter / 2, 0, 0, 0 } })
    end
    return page
end

------------------------------------------------------------------------------------------
-- The window
------------------------------------------------------------------------------------------

local switcher = nil
local tabs = {}
local statusText = nil
local statusClear = 0
local windowSlot = nil
local blocker = nil
local playerChip = nil

local POSITIONS = {
    left   = { anchor = 0.0, align = 0.0, x = 48 },
    center = { anchor = 0.5, align = 0.5, x = 0 },
    right  = { anchor = 1.0, align = 1.0, x = -48 },
}

function M.applyPosition(name)
    local p = POSITIONS[name] or POSITIONS.left
    if windowSlot == nil then
        return
    end
    try("window anchors", function()
        windowSlot:SetAnchors({ Minimum = { X = p.anchor, Y = 0.5 }, Maximum = { X = p.anchor, Y = 0.5 } })
    end)
    try("window alignment", function() windowSlot:SetAlignment({ X = p.align, Y = 0.5 }) end)
    try("window position", function() windowSlot:SetPosition({ X = p.x, Y = 0 }) end)
end

function M.setBlocker(on)
    if blocker ~= nil then
        M.setVisible(blocker, on)
    end
end

-- Shows msg in the footer for a few seconds. kind: "good", "bad", "warn" or nil.
function M.toast(msg, kind)
    core.log(msg,kind=="bad" and "Fehler" or kind=="warn" and "Warnung" or "Status")
    if statusText == nil then
        return
    end
    local color = (kind == "good" and C.good) or (kind == "bad" and C.bad)
        or (kind == "warn" and C.warn) or C.text2
    M.setText(statusText, msg, color)
    statusClear = os.clock() + 7
end

-- Pages are built the first time their tab is opened, so the first open of the menu
-- stays quick. A failed build leaves the page empty and logs why.
local function ensurePage(i)
    local slot = M.pages[i]
    if slot == nil or slot.built then
        return slot
    end
    slot.built = true
    local before = counter
    local started=os.clock()
    local traced = M.trace
    M.trace = M.traceBuilds
    step("build page " .. slot.title)
    local ok, page = core.safe("build page " .. slot.title, slot.build, M)
    M.trace = traced
    if ok and page ~= nil then
        page.built = true
        page.container = slot.container
        M.pages[i] = page
        M.content(slot.container, page.root)
        M.metrics.buildMs=(os.clock()-started)*1000
        M.metrics.widgets=counter
        core.log(string.format("page %s built: %d widgets, %.1f ms", slot.title, counter - before,M.metrics.buildMs))
        return page
    end
    return slot
end

function M.selectPage(i)
    if switcher == nil or M.pages[i] == nil then
        return
    end
    ensurePage(i)
    local changed=M.activePage~=i
    if changed then core.log("Seite: "..M.pages[i].title) end
    M.activePage = i
    try("switch page", function() switcher:SetActiveWidgetIndex(i - 1) end)
    for j, tab in ipairs(tabs) do
        local on = j == i
        M.setText(tab.label, tab.caption, on and C.text or C.text2)
        M.setVisible(tab.line, on, true)
    end
    local page = M.pages[i]
    if page.onShow ~= nil then
        core.safe("page onShow", page.onShow)
    end
    M.refreshActive()
end

function M.refreshActive()
    local page = M.pages[M.activePage]
    if page == nil then
        return
    end
    local started=os.clock()
    for _, fn in ipairs(page.refreshers) do
        core.safe("Anzeige "..page.title,fn)
    end
    M.metrics.refreshMs=(os.clock()-started)*1000
    M.metrics.refreshMaxMs=math.max(M.metrics.refreshMaxMs,M.metrics.refreshMs)
end

local function buildHeader(parent, keyName)
    local header = M.border(C.header, 0, nil, { 18, 12, 14, 10 })
    local hb = M.hbox()
    M.content(header, hb)

    local logo = M.border(C.accent, 8)
    M.content(logo, M.text("W", 13, C.accentInk, true, 1), CENTER, CENTER)
    M.add(hb, M.sizeBox(32, 32, logo), { v = CENTER, pad = { 0, 0, 11, 0 } })

    local titles = M.vbox()
    local name = M.hbox()
    M.add(name, M.text("WARDEN", F.title, C.text, true), { v = M.BOTTOM })
    M.add(name, M.text(" \u{00B7} ADMIN", F.title, C.accent, true), { v = M.BOTTOM })
    M.add(titles, name)
    M.add(titles, M.text("THE LAST CARETAKER  \u{2022}  CONTROL SYSTEM", F.subtitle, C.text2))
    M.add(hb, titles, { v = CENTER, fill = true })

    playerChip = M.text("", F.small, C.text2, false, 2)
    M.add(hb, playerChip, { v = CENTER, pad = { 0, 0, 12, 0 } })

    local badge = M.border(C.clear, R, C.accent, { 9, 3 })
    M.content(badge, M.text(keyName, F.badge, C.text, true, 1), CENTER, CENTER)
    local badgeCol = M.vbox()
    M.add(badgeCol, badge, { h = CENTER })
    M.add(badgeCol, M.text("Menü", 6.5, C.text2, false, 1), { h = CENTER, pad = { 0, 2, 0, 0 } })
    M.add(hb, badgeCol, { v = CENTER, pad = { 0, 0, 10, 0 } })

    M.button(hb, "\u{00D7}", "ghost", function() M.hide() end,
        { pad = { 9, 3 }, size = 11, slot = { v = CENTER } })

    M.add(parent, header)
end

local function buildTabBar(parent)
    local bar = M.hbox()
    for i, page in ipairs(M.pages) do
        local w = M.clickable("tab", function() M.selectPage(i) end)
        local col = M.vbox()
        local caption = string.upper(page.title)
        local label = M.text(caption, F.tab, C.text2, true, 1)
        M.add(col, label, { h = CENTER, pad = { 0, 0, 0, 5 } })
        local line = M.sizeBox(nil, 2, M.border(C.accent, 1))
        M.add(col, line, { h = FILL })
        M.setButtonContent(w, col, { 12, 7, 12, 0 })
        M.add(bar, w, { v = FILL })
        tabs[i] = { label = label, line = line, caption = caption }
    end
    local wrap = M.border(C.header, 0, nil, { 12, 0, 12, 0 })
    M.content(wrap, bar, LEFT)
    M.add(parent, wrap)
    M.add(parent, M.sizeBox(nil, 1, M.border(C.divider, 0)))
end

local function buildFooter(parent)
    local footer = M.border(C.header, 0, nil, { 18, 7, 18, 8 })
    local hb = M.hbox()
    M.content(footer, hb)
    local dot = M.sizeBox(6, 6, M.border(C.good, 3))
    M.add(hb, M.text("WARDEN v" .. core.VERSION .. "  |  ", F.small, C.muted), { v = CENTER })
    M.add(hb, dot, { v = CENTER, pad = { 0, 0, 5, 0 } })
    M.add(hb, M.text("CARETAKER", F.small, C.muted), { v = CENTER, pad = { 0, 0, 14, 0 } })
    statusText = M.text("Bereit.", F.small, C.text2)
    try("status clip", function() statusText:SetTextOverflowPolicy(1) end)
    M.add(hb, statusText, { v = CENTER, fill = true })
    M.add(hb, M.text("Strg+F1 = Eingabe freigeben", F.small, C.muted), { v = CENTER })
    M.add(parent, M.sizeBox(nil, 1, M.border(C.divider, 0)))
    M.add(parent, footer)
end

local function resolveClasses()
    for kind, path in pairs(CLASSES) do
        cls[kind] = core.find(path)
        if cls[kind] == nil then
            error("engine widget class missing: " .. path)
        end
    end
    menuButtonClass = core.loadClass(MENU_BUTTON)
    if menuButtonClass == nil then
        error("the game's menu button blueprint could not be loaded")
    end
    for _, path in ipairs(T.FONT_PATHS) do
        fontObject = core.find(path)
        if fontObject == nil and LoadAsset ~= nil then
            pcall(LoadAsset, path)
            fontObject = core.find(path)
        end
        if fontObject ~= nil then
            break
        end
    end
    if fontObject == nil then
        core.log("no font found - text will use the engine default")
    end
    wbl = core.lib("widgets")
    if wbl == nil then
        error("WidgetBlueprintLibrary missing")
    end
    spawner = core.lib("gameplay")
    if spawner == nil then
        error("GameplayStatics missing")
    end
end

-- Removes a Warden window left behind by a previous load of this mod (RestartMod).
-- Only live instances under /Engine/Transient are touched, never class templates.
local function removeLeftovers()
    step("FindAllOf menu buttons")
    for _, w in ipairs(FindAllOf("BP_VoyageCheat_MenuButton_Widget_C") or {}) do
        local full = core.fullName(w)
        if full:find("/Engine/Transient", 1, true) ~= nil then
            local ok, text = pcall(function() return core.str(w.Text) end)
            if ok and text == HOST_MARK then
                pcall(function() w:RemoveFromParent() end)
                core.log("removed a Warden window left from a previous load")
            end
        end
    end
end

-- Builds the window frame. builders is a list of { title, build } where build(ui)
-- creates the page with ui.newPage and returns it; it runs on the tab's first visit.
function M.build(builders, settings)
    local pc = core.pc()
    if pc == nil then
        error("no player controller")
    end
    resolveClasses()
    if not ensureHook() then
        error("click hook unavailable")
    end
    removeLeftovers()

    handlers = {}
    M.pages = {}
    tabs = {}
    counter = 0

    step("Create host")
    host = wbl:Create(pc, menuButtonClass, pc)
    if not core.isValid(host) then
        error("could not create the host widget")
    end
    try("host mark", function() host.Text = HOST_MARK end)
    step("host WidgetTree")
    tree = host.WidgetTree
    if not core.isValid(tree) then
        error("host has no widget tree")
    end
    hostPc = core.address(pc)

    local root = spawn(cls.CanvasPanel, "CanvasPanel")
    step("RootWidget")
    tree.RootWidget = root

    -- A transparent full screen button behind the window swallows clicks that miss the
    -- window, so they do not reach the game as tool or weapon use.
    blocker = spawn(cls.Button, "Button")
    -- FLinearColor is only 0x10 bytes. Do not pass a whole FButtonStyle to SetStyle.
    try("blocker tint", function() blocker:SetBackgroundColor(C.clear) end)
    try("blocker focus", function() blocker.IsFocusable = false end)
    step("AddChildToCanvas blocker")
    local bslot = root:AddChildToCanvas(blocker)
    try("blocker layout", function()
        bslot:SetAnchors({ Minimum = { X = 0, Y = 0 }, Maximum = { X = 1, Y = 1 } })
        bslot:SetOffsets(margin(0))
    end)

    -- Unhandled clicks bubble through PARENTS, never through a sibling behind the
    -- window. This transparent parent catches clicks on labels, padding and headers.
    -- It stays active even when blocking clicks OUTSIDE the menu is disabled.
    local sink = spawn(cls.Button, "Button (window click sink)")
    try("window sink tint", function() sink:SetBackgroundColor(C.clear) end)
    try("window sink focus", function() sink.IsFocusable = false end)
    local window = M.border(C.window, T.metric.windowRadius, C.panelBorder, 0)
    local sinkSlot = M.content(sink, window)
    try("window sink padding", function() sinkSlot:SetPadding(margin(0)) end)
    step("AddChildToCanvas window")
    windowSlot = root:AddChildToCanvas(sink)
    try("window size", function()
        windowSlot:SetSize({ X = T.metric.windowWidth, Y = T.metric.windowHeight })
    end)
    try("window z", function() windowSlot:SetZOrder(10) end)
    M.applyPosition(settings.position)

    local frame = M.vbox()
    M.content(window, frame)
    buildHeader(frame, settings.keyName)

    -- One empty container per page; the content is built on first visit.
    switcher = M.new("WidgetSwitcher")
    for _, def in ipairs(builders) do
        local container = M.new("SizeBox")
        M.add(switcher, container)
        M.pages[#M.pages + 1] = {
            title = def.title, build = def.build, built = false, container = container, refreshers = {},
        }
    end
    buildTabBar(frame)
    M.add(frame, switcher, { fill = true })
    buildFooter(frame)

    step("AddToViewport")
    host:AddToViewport(400)
    try("host visibility", function() host:SetVisibility(COLLAPSED) end)
    M.isOpen = false
    M.selectPage(1)
    core.log(string.format("window built: %d pages, %d widgets, font %s, brushes %s, button styles %s",
        #M.pages, counter, fontObject and core.shortName(fontObject) or "default",
        brushWorks and "rounded" or "flat", styleWorks and "custom" or "flat"))
end

-- True when the window exists and belongs to the current player controller.
function M.isBuilt()
    if not core.isValid(host) or not core.isValid(tree) then
        return false
    end
    local pc = core.pc()
    if pc == nil or core.address(pc) ~= hostPc then
        return false
    end
    local ok, inViewport = pcall(function() return host:IsInViewport() end)
    return ok and inViewport == true
end

------------------------------------------------------------------------------------------
-- Showing and input
------------------------------------------------------------------------------------------

M.walkWhileOpen = true

local function grabInput()
    local pc = core.pc()
    local lib = core.lib("widgets")
    if pc == nil or lib == nil then
        return
    end
    -- EMouseLockMode 0 = DoNotLock. Game and UI: the mouse works the menu and, when
    -- allowed, the movement keys still walk.
    try("input mode", function() lib:SetInputMode_GameAndUIEx(pc, host, 0, false, false) end)
    try("ignore look", function() pc:SetIgnoreLookInput(true) end)
    if not M.walkWhileOpen then
        try("ignore move", function() pc:SetIgnoreMoveInput(true) end)
    end
    try("cursor", function() pc.bShowMouseCursor = true end)
end

function M.releaseInput()
    local pc = core.pc()
    local lib = core.lib("widgets")
    if pc == nil then
        return
    end
    -- The ignore flags are counters; ResetIgnoreInputFlags clears them however often
    -- they were raised. SetInputMode_GameOnly needs both arguments, or it fails and
    -- leaves the player stuck in UI mode.
    try("reset ignore", function() pc:ResetIgnoreInputFlags() end)
    if lib ~= nil then
        try("game only", function() lib:SetInputMode_GameOnly(pc, false) end)
    end
    try("cursor off", function() pc.bShowMouseCursor = false end)
end

function M.show()
    if not core.isValid(host) then
        return
    end
    local traced = M.trace
    M.trace = M.traceBuilds
    try("show", function() host:SetVisibility(SELF_HIT_TEST_INVISIBLE) end)
    M.isOpen = true
    core.log("Menue geoeffnet")
    grabInput()
    M.trace = traced
    M.selectPage(M.activePage > 0 and M.activePage or 1)
end

function M.hide()
    if M.isOpen then core.log("Menue geschlossen") end
    if core.isValid(host) then
        try("hide", function() host:SetVisibility(COLLAPSED) end)
    end
    M.isOpen = false
    M.releaseInput()
end

-- Called a few times a second while the window is open.
function M.tick()
    if not M.isOpen or not core.isValid(host) then
        return
    end
    M.refreshActive()
    if statusText ~= nil and statusClear > 0 and os.clock() > statusClear then
        statusClear = 0
        M.setText(statusText, "Bereit.", C.text2)
    end
    if playerChip ~= nil then
        local pawn = core.pawn()
        local x, y, z = nil, nil, nil
        if pawn ~= nil then
            x, y, z = core.location(pawn)
        end
        if x ~= nil then
            M.setText(playerChip, string.format("X %d  Y %d  Z %d", x // 100, y // 100, z // 100))
        else
            M.setText(playerChip, "")
        end
    end
end

-- Forget the window, e.g. after the world changed. The widgets themselves are owned
-- by the old viewport and go away with it.
function M.reset()
    textState,visibleState,styleState={},{},{}
    host = nil
    tree = nil
    switcher = nil
    statusText = nil
    windowSlot = nil
    blocker = nil
    playerChip = nil
    handlers = {}
    M.pages = {}
    M.isOpen = false
end

M.C = C
M.F = F
return M
