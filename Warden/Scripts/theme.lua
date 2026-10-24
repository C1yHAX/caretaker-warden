--[[
    theme.lua - colours, type sizes and metrics of the Warden menu.

    Colours are written as sRGB hex, the way a designer picks them, and converted to
    linear here. Slate expects FLinearColor and converts to sRGB on output, so passing
    the hex values straight through would draw every surface noticeably lighter than
    intended.
--]]

local T = {}

local function toLinear(c)
    if c <= 0.04045 then
        return c / 12.92
    end
    return ((c + 0.055) / 1.055) ^ 2.4
end

-- hex(0x2DD4BF) or hex(0x2DD4BF, 0.5)
local function hex(rgb, alpha)
    local r = ((rgb >> 16) & 0xFF) / 255
    local g = ((rgb >> 8) & 0xFF) / 255
    local b = (rgb & 0xFF) / 255
    return { R = toLinear(r), G = toLinear(g), B = toLinear(b), A = alpha or 1.0 }
end
T.hex = hex

T.color = {
    window        = hex(0x0D1116, 0.97),
    header        = hex(0x10151B, 1.0),
    panel         = hex(0x141A21),
    panelBorder   = hex(0x212932),
    control       = hex(0x1A2129),
    controlHover  = hex(0x222B35),
    controlPress  = hex(0x2A3440),
    controlBorder = hex(0x2A333E),
    rowHover      = hex(0xFFFFFF, 0.045),
    rowPress      = hex(0xFFFFFF, 0.08),
    divider       = hex(0x1C232C),

    accent        = hex(0x2DD4BF),
    accentHover   = hex(0x5EEAD4),
    accentPress   = hex(0x14B8A6),
    accentDim     = hex(0x123632),
    accentInk     = hex(0x05201D),

    text          = hex(0xE7ECF2),
    text2         = hex(0x8C97A6),
    section       = hex(0xA3AEBC),
    muted         = hex(0x5E6977),

    good          = hex(0x4ADE80),
    warn          = hex(0xFBBF24),
    bad           = hex(0xF87171),

    clear         = { R = 0, G = 0, B = 0, A = 0 },
    white         = { R = 1, G = 1, B = 1, A = 1 },
}

-- Slate font sizes (points). Kept small on purpose: the menu is meant to be compact.
T.font = {
    title    = 15,
    subtitle = 7,
    tab      = 8.5,
    label    = 9,
    small    = 8,
    section  = 7.5,
    value    = 9,
    badge    = 8,
}

T.metric = {
    windowWidth   = 860,
    windowHeight  = 580,
    windowRadius  = 10,
    panelRadius   = 7,
    controlRadius = 5,
    gutter        = 12,
    cardPadding   = 11,
    rowHeight     = 24,
}

T.FONT_PATHS = {
    "/Game/UI/VoyageRoboto.VoyageRoboto",
    "/Engine/EngineFonts/Roboto.Roboto",
}

return T
