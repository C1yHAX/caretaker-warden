local tr = require("i18n").t
local core = require("core")
local M = {}
local DAMAGE = "/Script/Voyage.VoyageDestructibleObjectComponent"
local RANGES = {10, 25, 50, 100, 250}
local rangeIndex, job, uiRef = 1, nil, nil
local CELL = 5000 -- cm: at most a 50 x 50 m column per spatial query
local QUERY_LIMIT, MAX_SPLITS = 128, 3
local CHECKS_PER_TICK = 8
local OBJECT_TYPES = {0, 1, 2, 3, 4, 5} -- standard UE object-query channels
local ACTOR = "/Script/Engine.Actor"
local status = tr("Bereit")

local function finite(n) return type(n)=="number" and n==n and math.abs(n)<math.huge end
local function call(o, fn, ...)
    if not core.isValid(o) then return false end
    local args=table.pack(...)
    return pcall(function() return o[fn](o,table.unpack(args,1,args.n)) end)
end
local function read(o, key)
    if not core.isValid(o) then return nil end
    local ok,v=pcall(function() return o[key] end)
    if ok then return v end
end
local function identity(o)
    if not core.isValid(o) then return nil end
    local a,n=core.address(o),core.fullName(o)
    if a and a~=0 and n~="?" then return tostring(a).."|"..n end
end
local function world(o)
    local ok,level=call(o,"GetLevel")
    return ok and identity(read(level,"OwningWorld")) or nil
end

-- The indicator blueprint updates mesh material scalars, decals and damage points.
-- Its durability parameter is a fraction (full health = 1), independent of max HP.
-- Reapply it even at full HP: an earlier health-only repair may have left the
-- material stale. Only the owner's primary damage component drives its visuals.
local INDICATOR = "/Script/Voyage.VoyageDurabilityIndicatorComponent"
local function refreshVisuals(component, owner)
    local cls = core.find(INDICATOR)
    if not cls then return end
    local found, indicator = call(owner, "GetComponentByClass", cls)
    if not found or not core.isValid(indicator) then return end
    local owned, parent = call(indicator, "GetOwner")
    local got, primary = call(owner, "GetComponentByClass", core.find(DAMAGE))
    if not owned or identity(parent) ~= identity(owner) or not got or identity(primary) ~= identity(component) then return end
    local ok = call(indicator, "UpdateDurability", 1.0)
    return ok and read(indicator, "DurabilityLast") == 1
end

-- The original cheat widget repairs a module's actual destructible component
-- with OverrideHealth(GetMaxDurability()). Module:Repair instead applies negative
-- damage through TakeDamage; it can be filtered by the damage path.
-- Scalar-only ProcessEvent (4 bytes). Never pass DestructibleObjectProperties
-- itself: that struct is larger than this UE4SS build's 512-byte parameter buffer.
function M.damage(component, owner, maximum)
    local typed,yes=call(component,"IsA",DAMAGE)
    local owned,actualOwner=call(component,"GetOwner")
    if not typed or yes~=true or not owned or not identity(owner) or identity(actualOwner)~=identity(owner) then return "failed" end
    local before=read(component,"Health")
    if maximum==nil then
        local ok,v=pcall(function() return component.DestructibleObjectProperties.Health end)
        maximum=ok and v or nil
    end
    if not finite(before) or not finite(maximum) or maximum<=0 or maximum>3.402823466e38 then return "failed" end
    if before>=maximum then return "healthy", refreshVisuals(component,owner) end
    local ok=call(component,"OverrideHealth",maximum)
    local after=read(component,"Health")
    if ok and finite(after) and after>=maximum-math.max(1e-5,maximum*1e-6) then return "fixed", refreshVisuals(component,owner) end
    if ok and finite(after) and after>before then return "partial" end
    return "failed"
end

local function say(message,good)
    status=message
    core.log("Area repair: "..message)
    if uiRef then uiRef.toast(message,good and "good" or "warn") end
end
function M.cancel()
    if not job then return end
    local count=job.fixed
    job=nil
    say(string.format(tr("Reparatur abgebrochen; %d Objekte bereits repariert"),count),false)
end
-- Job records contain ONLY Lua scalars/tables, never UObject or out-param
-- wrappers. Streaming may remove an actor within the same world/controller.
local function record(object)
    if not core.isValid(object) then return nil end
    local full=core.fullName(object)
    local path=full:match("^%S+%s+(/.+)$")
    local address=core.address(object)
    if path and address and address~=0 then return {path=path,address=address} end
end
local function resolve(r)
    local object=core.find(r.path)
    if object and core.address(object)==r.address then return object end
end
local function inScope(owner,j)
    if world(owner)~=j.world then return false end
    local ok,dead=call(owner,"IsActorBeingDestroyed")
    local host,authority=call(owner,"HasAuthority")
    local typed,isPawn=call(owner,"IsA","/Script/Engine.Pawn")
    local vehicle,isVehicle=call(owner,"IsA","/Script/Voyage.VoyageVehiclePawn")
    if not ok or dead~=false or not host or authority~=true or not typed or not vehicle or (isPawn and not isVehicle) then return false end
    local x,y,z=core.location(owner)
    return finite(x) and finite(y) and finite(z) and (x-j.x)^2+(y-j.y)^2+(z-j.z)^2<=(j.radius*100)^2
end
local function enqueueTile(j,x,y,half,depth)
    local dx,dy=math.max(0,math.abs(x-j.x)-half),math.max(0,math.abs(y-j.y)-half)
    if dx*dx+dy*dy<=(j.radius*100)^2 then j.tiles[#j.tiles+1]={x=x,y=y,half=half,depth=depth} end
end
local function finish(j)
    job=nil
    say(string.format(tr("Umkreis %d m: %d repariert, %d intakt, %d teilweise, %d Fehler; %d uebersprungen"),
        j.radius,j.fixed,j.healthy,j.partial,j.failed,j.skipped)
        .. string.format(tr(" | Schadensanzeige aktualisiert: %d"),j.visuals),j.failed==0 and j.partial==0)
end
function M.start()
    if job then return false,tr("Reparatur laeuft bereits") end
    local pawn=core.pawn()
    local w,p=world(pawn),identity(pawn)
    local x,y,z=core.location(pawn)
    if not w or not p or not finite(x) or not finite(y) or not finite(z) then return false,tr("Kein Spieler in einer Welt") end
    local ok,authority=call(pawn,"HasAuthority")
    if not ok or authority~=true then return false,tr("Nur der Host kann die Umgebung reparieren") end
    if not core.lib("system") or not core.find(ACTOR) or not core.find(DAMAGE) then return false,tr("Reparaturdaten konnten nicht gelesen werden") end
    local j={world=w,pawn=p,pc=identity(core.pc()),x=x,y=y,z=z,radius=RANGES[rangeIndex],
        visuals=0,fixed=0,healthy=0,partial=0,failed=0,skipped=0,checked=0,seen={},
        tiles={},tileNext=1,actors={},actorNext=1,components={},componentNext=1}
    local radius=j.radius*100
    local n=math.max(1,math.ceil(2*radius/CELL))
    local side=2*radius/n
    for ix=1,n do for iy=1,n do
        enqueueTile(j,x-radius+(ix-0.5)*side,y-radius+(iy-0.5)*side,side/2,0)
    end end
    job=j
    say(string.format(tr("Reparatur im Umkreis gestartet (%d m)"),j.radius),true)
    core.log(string.format("Area repair: %d spatial cells; no global component snapshot",#j.tiles))
    return true,status
end
local function queryTile(j,pawn)
    local tile=j.tiles[j.tileNext]
    if not tile then finish(j);return end
    j.tileNext=j.tileNext+1
    local holder={}
    local ok=call(core.lib("system"),"BoxOverlapActors",pawn,
        core.vec(tile.x,tile.y,j.z),core.vec(tile.half,tile.half,j.radius*100),
        OBJECT_TYPES,core.find(ACTOR),{pawn},holder)
    if not ok then
        j.failed=j.failed+1
        core.log("Area repair: spatial query failed")
        return
    end
    local list=holder.OutActors or holder
    if type(list)~="table" then j.failed=j.failed+1;return end
    if #list>QUERY_LIMIT then
        if tile.depth<MAX_SPLITS then
            local half=tile.half/2
            for _,dx in ipairs({-half,half}) do for _,dy in ipairs({-half,half}) do
                enqueueTile(j,tile.x+dx,tile.y+dy,half,tile.depth+1)
            end end
        else
            -- Do not synchronously walk an unbounded dense result. Keep the UI
            -- responsive and report an incomplete cell, never a false success.
            j.failed=j.failed+1
            core.log("Area repair: dense cell skipped, actors="..#list)
        end
        return
    end
    j.actors,j.actorNext={},1
    -- Consume native out-parameter wrappers now, before any frame boundary.
    for _,raw in ipairs(list) do
        local object=core.unwrap(raw)
        local r=record(object)
        if r then
            local key=r.path.."|"..r.address
            if not j.seen[key] then j.seen[key]=true;j.actors[#j.actors+1]=r end
        end
    end
end
local function inspectActor(j,r)
    local actor=resolve(r)
    if not actor or not inScope(actor,j) then j.skipped=j.skipped+1;return end
    local ok,components=call(actor,"K2_GetComponentsByClass",core.find(DAMAGE))
    if not ok or type(components)~="table" or #components>QUERY_LIMIT then j.failed=j.failed+1;return end
    j.components,j.componentNext={},1
    for _,raw in ipairs(components) do
        local component=core.unwrap(raw)
        local token=record(component)
        if token then token.owner=r;j.components[#j.components+1]=token end
    end
end
local function repairComponent(j,r)
    j.checked=j.checked+1
    local component,owner=resolve(r),resolve(r.owner)
    if not component or not owner or not inScope(owner,j) or read(component,"bInitialized")~=true then
        j.skipped=j.skipped+1;return false
    end
    local got,actualOwner=call(component,"GetOwner")
    if not got or core.address(actualOwner)~=r.owner.address then j.skipped=j.skipped+1;return false end
    local before=read(component,"Health")
    local ok,maximum=pcall(function() return component.DestructibleObjectProperties.Health end)
    if not ok or not finite(before) or not finite(maximum) or maximum<=0 then j.skipped=j.skipped+1;return false end
    if before<maximum then
        core.log("Area repair: apply "..r.path.." "..tostring(before).." -> "..tostring(maximum))
    end
    local result, visual=M.damage(component,owner,maximum)
    j[result]=j[result]+1
    if visual then j.visuals=j.visuals+1 end
    if visual==false then j.failed=j.failed+1;core.log("Area repair: visual refresh failed "..r.path) end
    return before<maximum or visual~=nil
end
function M.tick()
    local j=job
    if not j then return end
    local pawn=core.pawn()
    if world(pawn)~=j.world or identity(pawn)~=j.pawn or identity(core.pc())~=j.pc then M.onWorldChanged();return end
    local ok,authority=call(pawn,"HasAuthority")
    if not ok or authority~=true then M.cancel();return end
    local started,discovered=os.clock(),false
    for _=1,CHECKS_PER_TICK do
        local component=j.components[j.componentNext]
        if component then
            j.componentNext=j.componentNext+1
            if repairComponent(j,component) then break end
        else
            local actor=j.actors[j.actorNext]
            if actor then
                if discovered then break end
                discovered=true;j.actorNext=j.actorNext+1
                inspectActor(j,actor)
            else
                -- One local physics query per tick; never combine it with repair.
                if discovered then break end
                queryTile(j,pawn);break
            end
        end
        if os.clock()-started>=0.003 then break end
    end
    if job then status=string.format(tr("Reparatur: Bereich %d/%d, %d Bauteile geprueft, %d repariert"),
        math.min(j.tileNext-1,#j.tiles),#j.tiles,j.checked,j.fixed) end
end
function M.onWorldChanged()
    -- No UObject references are retained by the job.
    job=nil;status=tr("Reparatur beendet: Spieler oder Welt gewechselt")
end
function M.busy() return job~=nil end
function M.status() return status end
function M.addToPage(ui,page,parent)
    uiRef=ui
    local card=ui.card(parent,tr("Reparatur im Umkreis"))
    ui.stepperRow(page,card,tr("Umkreis"),{values=RANGES,index=function() return rangeIndex end,
        format=function(v) return v.." m" end,set=function(i) if RANGES[i] then rangeIndex=i end end})
    ui.button(card,tr("Alles im Umkreis reparieren"),"primary",function()
        local ok,msg=M.start();if not ok then ui.toast(msg,"warn") end
    end)
    ui.button(card,tr("Reparatur abbrechen"),"action",M.cancel)
    ui.infoRow(page,card,tr("Ergebnis"),M.status)
    ui.add(card,ui.paragraph(tr("Repariert geladene Objekte mit Kollision im Umkreis. Grosse Bereiche werden in kleinen Schritten bearbeitet.")))
end
return M
