-- Construction diagnostics are READ ONLY unless the user explicitly repairs a
-- stalled job. Never add speculative writes to the normal building path.
local core = require("core")
local M = {}
local CLASS = "/Game/Blueprints/Fabrication/BP_Location_Fabricator.BP_Location_Fabricator_C"
local ELECTRICITY = 0 -- EModuleResourceType, not EVoyageInventoryType
local status = "Noch nicht geprueft"
local countdown, seen = 0, {}
local function call(o, fn, ...)
    if not core.isValid(o) then return nil end
    local args = table.pack(...)
    local ok, v = pcall(function() return o[fn](o, table.unpack(args,1,args.n)) end)
    if ok then return v end
    return nil
end
local function read(o, key)
    local ok,v=pcall(function() return o[key] end)
    if ok then
        if (key=="ModuleComponent" or key=="InventoryComponent") and core.unwrap then return core.unwrap(v) end
        return v
    end
    return nil
end
local function number(v) return type(v)=="number" and v==v and math.abs(v)<math.huge end
local function same(a,b)
    return core.isValid(a) and core.isValid(b) and core.address(a)==core.address(b)
end
function M.fillEnergy()
    local pawn=core.pawn()
    local module=call(pawn,"GetPlayerEquippedModule",ELECTRICITY)
    if not core.isValid(module) then module=call(pawn,"GetPlayerModule") end
    local current=call(module,"GetResourceAmount",ELECTRICITY)
    local maximum=call(module,"GetMaxResourceAmount",ELECTRICITY)
    if not number(current) or not number(maximum) or maximum<=0 then
        return false,"Keine lesbare Spielerbatterie"
    end
    if current<maximum then call(module,"ForceAddResource",ELECTRICITY,maximum-current) end
    local after=call(module,"GetResourceAmount",ELECTRICITY)
    local ok=number(after) and after>=maximum-0.001
    return ok,ok and "Spielerbatterie fuer Bauauftraege geladen" or "Batterieladung nicht bestaetigt"
end
local function joinCount(module)
    local values=read(module,"JoinUpdateObjects")
    -- Elements are FVoyageJoinUpdateObject containing a SOFT pointer (0x28),
    -- not UObject*. Do not read/marshal those elements with this UE4SS build.
    if type(values)=="table" then return #values end
    local ok,n=pcall(function() return values:GetArrayNum() end)
    if not ok or not number(n) or n<0 or n>4096 then return nil end
    return n
end
function M.inspect(repair)
    local pawn=core.pawn()
    if not core.isValid(pawn) then return false,"Kein Spieler" end
    local module=call(pawn,"GetPlayerModule")
    if not core.isValid(module) then return false,"Kein Spieler-Baumodul" end
    local checked,relinked,paused,failed=0,0,0,0
    local alive={}
    for _,actor in ipairs(core.actorsOf(CLASS)) do
        -- Scope by native ownership, not by proximity to another player's build.
        if same(call(actor,"GetOwner"),pawn) then
            local fab=read(actor,"VoyageFabricator")
            if core.isValid(fab) and call(fab,"HasWork")==true then
                checked=checked+1
                local id=tostring(core.address(actor))..core.fullName(actor)
                alive[id]=true
                local before=joinCount(module)
                if repair and same(read(fab,"ModuleComponent"),module) then
                    -- JoinUpdate alone leaves the existing cached thread-routing
                    -- flag unchanged. Rebuild through native APIs, not TArray edits.
                    -- Best effort rejoin runs even when the leave call fails.
                    call(module,"LeaveUpdate",fab)
                    local middle=joinCount(module)
                    call(module,"JoinUpdate",fab)
                    local after=joinCount(module)
                    if before and middle and after and after==middle+1 and after>=before then
                        relinked=relinked+1
                    else failed=failed+1 end
                end
                -- The game's own overlap test decides whether to unpause.
                if repair then call(actor,"UpdatePause") end
                local isPaused=call(fab,"IsPaused")
                if isPaused then paused=paused+1 end
                local remaining=read(fab,"ProgressTimerRemaining")
                local max=read(fab,"ProgressTimerMax")
                local key=table.concat({tostring(isPaused),tostring(remaining),tostring(max)},"/")
                local previous=seen[id]
                if repair or not previous or (previous.key==key and previous.repeats==2) then
                    core.log(string.format("Building: %s paused=%s blocked=%s subscriptions=%s remaining=%s max=%s craftSpeed=%s buildSpeed=%s power=%s energy=%s state=%s",
                        core.shortName(actor),tostring(isPaused),tostring(read(actor,"IsBlocked")),tostring(joinCount(module)),
                        tostring(remaining),tostring(max),tostring(read(fab,"CraftSpeed")),tostring(read(fab,"BuildSpeed")),
                        tostring(call(module,"HasPower")),tostring(call(module,"GetTotalResourcesAmountForType",ELECTRICITY)),
                        tostring(call(module,"GetModuleState"))))
                    local inv=read(fab,"InventoryComponent")
                    core.log(string.format("Building detail: fabricating=%s override=%s ignoreRequirements=%s requirements=%s initialized=%s moduleTick=%s lastModuleTime=%s localEnergy=%s capacity=%s craftConsumption=%s buildConsumption=%s inventory=%s outputTimer=%s",
                        tostring(call(fab,"IsFabricating")),tostring(read(fab,"bPauseOverride")),tostring(read(fab,"bIgnoreModuleRequirements")),
                        tostring(read(module,"bRequirementsMet")),tostring(read(module,"bHasInitialized")),tostring(read(module,"bTickEnabled")),
                        tostring(read(module,"LastUpdatedWorldTime")),tostring(call(module,"GetResourceAmount",ELECTRICITY)),
                        tostring(call(module,"GetMaxResourceAmount",ELECTRICITY)),tostring(read(fab,"CraftConsumption")),tostring(read(fab,"BuildConsumption")),
                        core.isValid(inv) and core.fullName(inv) or "invalid",tostring(read(fab,"OutputTimer"))))
                end
                seen[id]={key=key,repeats=not repair and previous and previous.key==key and previous.repeats+1 or 0}
            end
        end
    end
    for id in pairs(seen) do if not alive[id] then seen[id]=nil end end
    status=string.format("%d Bauauftraege; %d pausiert; %d neu angebunden%s",checked,paused,relinked,
        failed>0 and ("; "..failed.." Anbindungen unbestaetigt") or "")
    if repair then status=status..". Baufortschritt wird weiter geprueft." end
    return true,status
end
function M.tick()
    countdown=countdown+1
    if countdown%20==0 then M.inspect(false) end -- observe only: no automatic gameplay writes
end
function M.onWorldChanged() seen,countdown,status={},0,"Warte auf Bauauftrag" end
function M.addToPage(ui,page,parent)
    local card=ui.card(parent,"Bauen & Diagnose")
    ui.infoRow(page,card,"Bauauftraege",function() return status end)
    ui.button(card,"Bauauftraege pruefen / reaktivieren","action",function()
        local ok,msg=M.inspect(true);ui.toast(msg,ok and "good" or "bad")
    end)
    ui.button(card,"Spielerbatterie laden","action",function()
        local ok,msg=M.fillEnergy();ui.toast(msg,ok and "good" or "bad")
    end)
    ui.add(card,ui.paragraph("Prueft eigene Bauauftraege aus dem B-Menue. Materialien, Kollisionen und Recycling bleiben nach Spielregeln."))
end
return M
