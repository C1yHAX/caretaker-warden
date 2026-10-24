-- Search metadata only; never changes game assets or inventory eligibility.
-- German aliases remain available when UE4SS exposes an English source string.
local core = require("core")
local M = {}
local MATERIALS = {
    Aluminium = "Aluminium Aluminum",
    CarbonFiber = "Kohlefaser Kohlenstofffaser Carbon Fiber",
    Cardboard = "Pappe Karton Cardboard",
    Copper = "Kupfer Copper",
    Fabric = "Stoff Textil Gewebe Fabric Cloth",
    Glass = "Glas Glass",
    Gold = "Gold",
    Graphene = "Graphen Graphene",
    Iron = "Eisen Iron",
    Marble = "Marmor Marble",
    Nanotubes = "Nanoröhren Nanoroehren Nanotubes",
    Neutronium = "Neutronium",
    PlasmaGel = "Plasmagel Plasma Gel",
    Plastic = "Kunststoff Plastik Plastic",
    Polycarbonate = "Polycarbonat Polykarbonat Polycarbonate",
    Polyurethane = "Polyurethan Polyurethane",
    QuantumCrystal = "Quantenkristall Quantum Crystal",
    Rubber = "Gummi Rubber",
    Silicon = "Silizium Silicon",
    StainlessSteel = "Edelstahl rostfreier Stahl Stainless Steel",
    Titanium = "Titan Titanlegierung Titanium",
}
local FOLD = { ["Ä"]="a", ["ä"]="a", ["Ö"]="o", ["ö"]="o", ["Ü"]="u", ["ü"]="u", ["ß"]="ss", ["ẞ"]="ss" }
function M.normalize(s)
    s = tostring(s or "")
    for from,to in pairs(FOLD) do s=s:gsub(from,to) end
    return s:lower():gsub("^%s+", ""):gsub("%s+$", "")
end
local function usable(s)
    return type(s)=="string" and s~="" and s~="None" and s~="?"
        and not s:find("MISSING STRING TABLE",1,true)
        and not s:find("MISSING_STRING_TABLE",1,true)
        and not s:match("^FText:") and not s:match("^userdata:")
end
function M.describe(value, path)
    local direct=core.str(value)
    local name=direct
    -- Native FText conversion resolves the current localized display text.
    -- UE4SS's direct ToString reads its own FText representation instead.
    -- InText + return FString = 32 bytes in the verified game dump.
    if value~=nil and type(value)~="string" then
        local lib=core.lib("text")
        if lib then
            local ok,text=pcall(function() return lib:Conv_TextToString(value) end)
            if ok then
                text=core.str(text)
                if usable(text) then name=text end
            end
        end
    end
    local material=path:match("^/Game/Data/Assets/Materials/DA_Material_([^%.]+)%.")
    local aliases=material and MATERIALS[material] or ""
    if not usable(name) then
        name=aliases:match("^(%S+)") or path:match("%.([^%.]+)$") or path
    end
    local search=M.normalize(table.concat({name,usable(direct) and direct or "",path,aliases}," "))
    return name,search
end
function M.matches(entry, query)
    if query=="" then return true end
    local search=entry.search or M.normalize((entry.name or "").." "..(entry.path or ""))
    return search:find(query,1,true)~=nil
end
return M
