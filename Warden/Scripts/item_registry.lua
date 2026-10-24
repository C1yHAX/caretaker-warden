-- Read registered VoyageItem assets, including unloaded items from mounted mods.
-- Keep only paths/primary types; never hold registry row userdata between ticks.
local core=require("core")
local M={}
local primaryTypes={}
local function field(o,k) local ok,v=pcall(function() return o[k] end);if ok then return core.unwrap(v) end end
local function liveRegistry()
    local ok,registries=pcall(FindAllOf,"AssetRegistryImpl")
    if not ok then return nil end
    for _,registry in ipairs(registries or {}) do
        registry=core.unwrap(registry)
        if core.isValid(registry) and not core.fullName(registry):find("Default__",1,true) then
            return registry
        end
    end
end
local function rowPath(row)
    local pkg,name=core.str(field(row,"PackageName")),core.str(field(row,"AssetName"))
    if type(pkg)=="string" and pkg:sub(1,1)=="/" and type(name)=="string" and name~="" and name~="None" then
        return pkg.."."..name
    end
end
function M.assetType(path)
    if primaryTypes[path] then return primaryTypes[path] end
    -- Metadata is queried only if normal loading failed, inside the bounded
    -- catalog tick. Discovery never issues one tag query per catalog entry.
    local registry,helper=liveRegistry(),core.find("/Script/AssetRegistry.Default__AssetRegistryHelpers")
    if not registry or not helper or not core.outValue then return nil end
    local getAssets=core.find("/Script/AssetRegistry.AssetRegistry:GetAssetsByPackageName")
    local rows=core.outList("item package metadata",function(holder)
        local pkg=FName(path:match("^(.+)%.[^%.]+$"),1)
        if getAssets then return getAssets(registry,pkg,holder,false,false) end
        return registry:GetAssetsByPackageName(pkg,holder,false,false)
    end,"OutAssetData")
    for _,row in ipairs(rows) do
        if rowPath(row)==path then
            local value=core.outValue("item primary asset type",function(holder)
                return helper:GetTagValue(row,FName("PrimaryAssetType",1),holder)
            end,"OutTagValue")
            local kind=core.str(value)
            if type(kind)=="string" and kind~="" and kind~="None" then primaryTypes[path]=kind end
            break
        end
    end
    return primaryTypes[path]
end
function M.paths()
    local result,seen={},{}
    local registry=liveRegistry()
    local getAssets=core.find("/Script/AssetRegistry.AssetRegistry:GetAssetsByClass")
    if registry then
            local rows=core.outList("inventory asset registry",function(holder)
                local classPath={PackageName=FName("/Script/Voyage",1),AssetName=FName("VoyageItem",1)}
                -- GetDerivedClassAssetData describes child CLASS assets. Here we
                -- need data assets whose class is VoyageItem or any subclass.
                if getAssets then return getAssets(registry,classPath,holder,true) end
                return registry:GetAssetsByClass(classPath,holder,true)
            end,"OutAssetData")
            for _,row in ipairs(rows) do
                local path=rowPath(row)
                if path then
                    if not seen[path] then
                        seen[path]=true;result[#result+1]=path
                    end
                end
            end
    end
    return result
end
return M
