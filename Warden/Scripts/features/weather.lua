local core = require("core")
local tr = require("i18n").t
local M = {}

local CLASS = "/Game/Blueprints/BP_WeatherVolumeActor.BP_WeatherVolumeActor_C"
local PRESET = "/Script/Voyage.VoyageWeatherPreset"
local FOLDER = "/Game/Data/Weather/WeatherPresets/"
-- Exact asset names from the game's cheat widget. "cloudy" is lowercase.
local function presets()
    return {
        {"Default", tr("Standard")}, {"Sunny", tr("Sonnig")}, {"cloudy", tr("Bewölkt")},
        {"Fog", tr("Nebel")}, {"Rain", tr("Regen")}, {"Storm", tr("Sturm")}, {"LightSnow", tr("Leichter Schneefall")},
    }
end
local selected, active = 2, nil

local function same(a,b)
    return core.isValid(a) and core.isValid(b) and core.address(a)==core.address(b)
end

local function worldKey(pawn)
    local ok,key=pcall(function()
        local world=pawn:GetLevel().OwningWorld
        if core.isValid(world) then return core.fullName(world).."|"..tostring(core.address(world)) end
    end)
    return ok and key or nil
end

local function current(key)
    if active and active.world==key then
        local obj=core.find(active.path)
        if obj and core.address(obj)==active.address and not obj:IsActorBeingDestroyed() then return obj end
    end
    active=nil
end

local function remove(actor)
    local ok, gone=pcall(function()
        actor:K2_DestroyActor()
        return not core.isValid(actor) or actor:IsActorBeingDestroyed()
    end)
    return ok and gone
end

function M.apply(index)
    local pawn, pc=core.pawn(), core.pc()
    local key=worldKey(pawn)
    if not key or not pc or pawn:HasAuthority()~=true then return false,tr("Wetterwechsel benötigt einen Host in der Spielwelt") end
    local old=current(key)
    if index==0 then
        if old and not remove(old) then return false,tr("Wettervorgabe konnte nicht entfernt werden") end
        active=nil
        return true,tr("Natürliches Wetter aktiv")
    end
    local choice=presets()[index]
    if not choice then return false,tr("Unbekannte Wetterlage") end
    local name="DA_WeatherPreset_"..choice[1]
    local path=FOLDER..name.."."..name
    local asset=core.find(path)
    if not asset and LoadAsset then pcall(LoadAsset,path);asset=core.find(path) end
    local cls=core.loadClass(CLASS)
    if not cls or not asset or asset:IsA(PRESET)~=true then return false,tr("Wettervorlage konnte nicht geladen werden") end

    local actor, token
    local ok,err=pcall(function()
        local gs=core.lib("gameplay")
        local transform=core.lib("math"):MakeTransform(pawn:K2_GetActorLocation(),core.rot(0,0,0),core.vec(1,1,1))
        actor=gs:BeginDeferredActorSpawnFromClass(pc,cls,transform,1,nil,1)
        assert(core.isValid(actor),"spawn")
        actor.VoyageWeatherPreset=asset
        assert(same(actor.VoyageWeatherPreset,asset),"preset")
        local finished=gs:FinishSpawningActor(actor,transform,1)
        assert(same(finished,actor),"finish")
        -- BeginPlay applies the preset after a latent delay. Set the same reference
        -- immediately as well, only on this session actor's own weather volume.
        local volume=actor.VoyageWeatherVolume
        assert(core.isValid(volume) and same(volume:GetOwner(),actor),"volume")
        volume.WeatherPreset=asset
        volume.Priority=100
        volume.Multiplier=1
        volume.Radius=1e9
        volume.Height=1e9
        assert(same(volume.WeatherPreset,asset) and volume.Priority==100 and volume.Multiplier==1
            and volume.Radius==1e9 and volume.Height==1e9,"volume readback")
        local objectPath=core.fullName(actor):match("^%S+%s+(/.+)$")
        assert(objectPath and same(core.find(objectPath),actor),"actor identity")
        token={world=key,path=objectPath,address=core.address(actor)}
        if old then assert(remove(old),"previous override") end
    end)
    if not ok then
        if core.isValid(actor) then remove(actor) end
        core.log("Weather: "..tostring(err))
        return false,tr("Wetterwechsel fehlgeschlagen")
    end
    active=token
    return true,tr("Wetter gesetzt").." · "..choice[2]
end

function M.onWorldChanged()
    -- Controller and pawn changes can occur within the same world.
    -- Resolve the token against the next valid world on the next action.
    local key=worldKey(core.pawn())
    if key and active and active.world~=key then active=nil end
end

function M.addToPage(ui,page,card)
    local choices=presets()
    ui.stepperRow(page,card,tr("Wetterlage"),{
        values=choices,width=142,wrap=true,note=tr("Für diese Spielsitzung"),index=function() return selected end,
        format=function(v) return v[2] end,
        set=function(i) if choices[i] then selected=i end end,
    })
    local function apply(i)
        local ok,msg=M.apply(i)
        ui.toast(msg,ok and "good" or "warn")
    end
    ui.button(card,tr("Wetter setzen"),"primary",function() apply(selected) end)
    ui.button(card,tr("Natürliches Wetter fortsetzen"),"action",function() apply(0) end)
end

return M
