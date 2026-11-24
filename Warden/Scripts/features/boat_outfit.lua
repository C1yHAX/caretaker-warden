local tr = require("i18n").t
-- Port of BP_VoyageCheatWiget.SetBoatEnginesLevel, used by TLC-AdminMenuMod.
-- SpawnActorForItem initializes the item and lets the physical sockets connect it.
-- A BP_Module_Crafter cannot be attached to these engines. Do not use it here.
-- SpawnActorForItem's complete parameter block is 0x168 bytes, below UE4SS's
-- 0x200 limit. ItemClass MUST be native TSoftObjectPtr userdata produced by the
-- engine, never a Lua table/string/UObject. See verification/boat-outfit-abi.json.
local core=require("core")
local M={}
local ENGINE="/Script/Voyage.VoyageModuleEngineActor"
local SNAP="/Script/Voyage.VoyagePhysicalSnapSocketComponent"
local PREFIX="/Game/Blueprints/Modules/Utility/Boat/"
local variants={DieselEngine=true,ElectricEngine=true}
local levels={"","_Booster","_SuperBooster","_CheatBooster"}
local names={DieselEngine="Diesel",ElectricEngine="Electric"}
local job
local status=tr("Noch nicht geprueft")
local function read(o,k) local ok,v=pcall(function() return o[k] end);if ok then return v end end
local function call(o,k,...)
    if not core.isValid(o) then return end
    local a=table.pack(...);local ok,v=pcall(function() return o[k](o,table.unpack(a,1,a.n)) end)
    if ok then return v end
end
local function same(a,b) return core.isValid(a) and core.isValid(b) and core.address(a)==core.address(b) end
local function finite(n) return type(n)=="number" and n==n and math.abs(n)<math.huge end
local function vector(v)
    local x,y,z=core.xyz(v)
    if finite(x) and finite(y) and finite(z) then return x,y,z end
end
local function isa(o,path) return call(o,"IsA",core.find(path))==true end
local function ident(o)
    if not core.isValid(o) then return end
    local p=core.fullName(o):match("^%S+%s+(/.+)$")
    if p then return {path=p,address=core.address(o)} end
end
local function resolve(id)
    if not id then return end
    local o=core.find(id.path)
    if core.isValid(o) and core.address(o)==id.address then return o end
end
local function array(a)
    -- UE4SS push_arrayproperty(GetNonTrivialLocal) creates a Lua table but uses
    -- GetParam for EACH element. Both representations need unwrapping, even the
    -- table returned by K2_GetComponentsByClass. Never test a wrapper as UObject.
    if type(a)=="table" then
        local result={}
        for i,v in ipairs(a) do
            if i>2048 then return {} end
            result[i]=core.unwrap(v)
        end
        return result
    end
    local ok,n=pcall(function() return a:GetArrayNum() end)
    if not ok or type(n)~="number" or n<0 or n>2048 then return {} end
    local result={}
    for i=1,n do result[#result+1]=core.unwrap(a[i]) end
    return result
end
local function linked(socket)
    -- AttachedToSocket is a WEAK object, not a UObject property.
    local weak=read(socket,"AttachedToSocket")
    local other=core.unwrap(weak)
    if not core.isValid(other) then
        local ok,v=pcall(function() return weak:Get() end)
        if ok then other=v end
    end
    if not core.isValid(other) then return end
    return call(read(other,"Owner"),"GetOwner"),other
end
local function cylinder(actor,kind)
    local n="BP_Module_"..names[kind].."_Engine_Cylinder"
    return isa(actor,PREFIX..n.."."..n.."_C")
end
local function belongs(actor,boat)
    for _=1,24 do
        if same(actor,boat) then return true end
        actor=call(actor,"GetAttachParentActor")
        if not core.isValid(actor) then return false end
    end
    return false
end
local function finish(reason)
    local j=job;job=nil
    if j then
        status=string.format(tr("%s: %d verbunden, %d uebersprungen, %d unbestaetigt"),reason,j.connected,j.skipped,j.failed)
        j.report(status,j.failed==0 and j.skipped==0 and j.connected>0 and j.index>#j.plan)
    end
end
local function scan(boat)
    local plan,seen,omitted={},{},0
    local stats={engines=0,components=0,diesel=0,electric=0,occupied=0,unknown=0}
    local attached=core.outList(tr("boot engines"),function(h) return boat:GetAttachedActors(h,true,true) end,"OutActors")
    for _,actor in ipairs(attached) do
        if isa(actor,ENGINE) and belongs(actor,boat) then
            stats.engines=stats.engines+1
            for _,comp in ipairs(array(call(actor,"K2_GetComponentsByClass",core.find(SNAP)))) do
                stats.components=stats.components+1
                local kind=core.str(read(comp,"SocketTypeOverride"))
                local plug=call(comp,"IsPlugSocket")
                local sockets=array(read(comp,"Sockets"))
                core.log(string.format(tr("Bootsanalyse: %s; Typ=%s; Stecker=%s; Anschluesse=%d"),
                    core.fullName(actor),tostring(kind),tostring(plug),#sockets))
                if variants[kind] and plug==false then
                    local n="BP_Module_"..names[kind].."_Engine_Cylinder"
                    core.loadClass(PREFIX..n.."."..n.."_C")
                    for _,socket in ipairs(sockets) do
                        local key=core.address(socket)
                        if key and not seen[key] and #plan<256 then
                            seen[key]=true
                            plan[#plan+1]={engine=ident(actor),component=ident(comp),socket=ident(socket),kind=kind}
                            local field=kind=="DieselEngine" and "diesel" or "electric"
                            stats[field]=stats[field]+1
                            local connected=linked(socket)
                            if cylinder(connected,kind) then stats.occupied=stats.occupied+1
                            elseif core.isValid(connected) then stats.unknown=stats.unknown+1 end
                        elseif key and not seen[key] then
                            omitted=omitted+1;seen[key]=true
                        end
                    end
                end
            end
        end
    end
    status=string.format(tr("%d Motoren; %d Diesel / %d Elektro; %d belegt; %d fremde Verbindungen"),
        stats.engines,stats.diesel,stats.electric,stats.occupied,stats.unknown)
    core.log(tr("Bootsanalyse: ")..status..string.format(tr("; %d Anbauteile; %d Anschlusskomponenten"),#attached,stats.components))
    return plan,omitted
end
function M.status() return status end
function M.inspect(boat)
    if not core.isValid(boat) or call(boat,"IsActorBeingDestroyed")~=false then return false,tr("Kein gueltiges Zielboot") end
    local plan=scan(boat)
    return #plan>0,status
end
function M.start(boat,level,report)
    if job then return false,tr("Ausstattung laeuft bereits") end
    if not finite(level) or not levels[level] or call(boat,"HasAuthority")~=true then return false,tr("Kein gueltiges Zielboot") end
    local plan,omitted=scan(boat)
    if #plan==0 then return false,tr("Keine passenden Motoranschluesse: ")..status end
    job={boat=ident(boat),pc=core.address(core.pc()),plan=plan,index=1,level=level,report=report,connected=0,skipped=omitted,failed=0}
    return true,string.format(tr("%d Motoranschluesse werden einzeln ausgeruestet"),#plan)
end
function M.cancel() if job then finish(tr("Ausstattung beendet")) end end
function M.onWorldChanged() job=nil;status=tr("Noch nicht geprueft") end
-- Prepare and round-trip the native soft reference BEFORE removing any cylinder.
-- This is a supported UE4SS property type; only hand-built soft-pointer tables
-- were unsafe. Keep its userdata alive until SpawnActorForItem has returned.
local function prepare(kind,level,engine)
    local name="DA_Item_"..names[kind].."EngineCylinder"..levels[level]
    local path="/Game/Data/Assets/Items/"..name.."."..name
    local item,reason,detail=require("features.packages").load(path)
    assert(core.isValid(item),tr("Motorzylinder nicht geladen")..": "..path.." "..tostring(detail or reason))
    local sys,misc=core.lib("system"),core.lib("misc")
    assert(core.isValid(sys) and core.isValid(misc),tr("Bootsausstattung: Spielfunktionen fehlen"))
    local soft=sys:Conv_ObjectToSoftObjectReference(item)
    assert(same(sys:LoadAsset_Blocking(soft),item),tr("Bootsausstattung: Itemreferenz nicht bestaetigt"))
    local world=misc:GetActorWorld(engine)
    assert(core.isValid(world),tr("Bootsausstattung: Spielwelt fehlt"))
    return misc,world,soft
end
local function clock(boat)
    local n=call(core.lib("gameplay"),"GetRealTimeSeconds",boat)
    assert(finite(n),tr("Bootsausstattung: Spielzeit nicht lesbar"))
    return n
end
local function tick()
    local j=job;if not j then return end
    if j.pc~=core.address(core.pc()) then job=nil;return end
    local boat=resolve(j.boat)
    if not boat or call(boat,"HasAuthority")~=true or call(boat,"IsActorBeingDestroyed")~=false then finish(tr("Zielboot nicht mehr verfuegbar"));return end
    local row=j.plan[j.index]
    if not row then finish(tr("Bootsausstattung fertig"));return end
    local engine,comp,socket=resolve(row.engine),resolve(row.component),resolve(row.socket)
    if not engine or not comp or not socket or not belongs(engine,boat)
        or not same(read(socket,"Owner"),comp) or not same(call(comp,"GetOwner"),engine)
        or call(engine,"HasAuthority")~=true then
        j.skipped=j.skipped+1;j.waitUntil=nil;j.index=j.index+1;return
    end
    local existing=linked(socket)
    if j.waitUntil then
        if cylinder(existing,row.kind) and same(existing,resolve(j.spawned)) then
            j.connected=j.connected+1;j.waitUntil=nil;j.index=j.index+1
            status=string.format(tr("%d/%d Motoranschluesse verbunden"),j.connected,#j.plan)
            core.log(tr("Bootsausstattung: ")..status)
        elseif clock(boat)>=j.waitUntil then
            j.failed=j.failed+1
            core.log(tr("Bootsausstattung: Zylinder erzeugt, Anschluss nicht bestaetigt"), tr("Warnung"))
            finish(tr("Einrasten unbestaetigt; weitere Wechsel gestoppt"))
        end
        return
    end
    -- A hull, engine, CO2 outlet or unknown connection is NEVER removed.
    local plugged=call(socket,"IsPlugged")
    if type(plugged)~="boolean" or (plugged and not cylinder(existing,row.kind))
        or (not plugged and core.isValid(existing)) then
        j.skipped=j.skipped+1;j.index=j.index+1;return
    end
    local misc,world,soft=prepare(row.kind,j.level,engine)
    local km=core.lib("math")
    -- Match the original: component location + rotated/scaled socket offset
    -- + electric Z offset + one frame of engine velocity (the boat can move).
    local rx,ry,rz=vector(read(socket,"RelativeLocation"))
    local sx,sy,sz=vector(read(comp,"RelativeScale3D"))
    local x,y,z=vector(call(comp,"K2_GetComponentLocation"))
    local vx,vy,vz=vector(call(engine,"GetVelocity"))
    local dt=call(core.lib("gameplay"),"GetWorldDeltaSeconds",boat)
    assert(rx and sx and x and vx and finite(dt) and dt>=0 and dt<=1,
        tr("Bootsausstattung: Anschlussposition nicht lesbar"))
    local offset=km:GreaterGreater_VectorRotator(core.vec(rx*sx,ry*sy,rz*sz),comp:K2_GetComponentRotation())
    local ox,oy,oz=vector(offset)
    assert(ox,tr("Bootsausstattung: Anschlussposition nicht lesbar"))
    x,y,z=x+ox+vx*dt,y+oy+vy*dt,z+oz+vz*dt
    if row.kind=="ElectricEngine" then z=z+50 end
    local transform=km:MakeTransform(core.vec(x,y,z),core.rot(0,row.kind=="ElectricEngine" and 180 or 0,0),core.vec(1,1,1))
    local now=clock(boat)
    local persistent=call(core.lib("subsystem"),"GetWorldSubsystem",boat,core.find("/Script/Voyage.VoyagePersistentSubsystem"))
    if core.isValid(existing) and not core.isValid(persistent) then
        error(tr("Bootsausstattung: Austausch nicht verfuegbar"))
    end
    if core.isValid(existing) then
        -- Original order: remove the old cylinder, then spawn its replacement.
        -- Unlike the old menu, NEVER delete an arbitrary connected actor/hull.
        -- All loading, reference and transform checks happen before this point.
        local current=linked(socket)
        if same(current,existing) and cylinder(existing,row.kind) and not same(existing,boat) and not same(existing,engine) then
            persistent:DestroyActor(existing,0.0)
            assert(not core.isValid(existing) or call(existing,"IsActorBeingDestroyed")==true
                or not same(linked(socket),existing),tr("Bootsausstattung: Alter Zylinder noch verbunden"))
        else
            j.skipped=j.skipped+1;j.index=j.index+1;return
        end
    end
    -- Same item data and settings as SetBoatEnginesLevel. No inventory, helper
    -- actor, rigid attachment, global scan, or modification of recipe assets.
    local spawned=array(misc:SpawnActorForItem(world,soft,transform,
        {ItemCount=1,Timestamp=os.time(),Flags=0,Version=30},
        {LinearVelocity=core.vec(0,0,0),AngularVelocity=core.vec(0,0,0),AutoCollectRadius=500,
         bForceAutoCollect=false,bResolveOverlaps=true,bAwake=true,bSimulatePhysics=true,
         BoxHalfExtents=core.vec(0,0,0)}))
    assert(#spawned==1 and cylinder(spawned[1],row.kind),tr("Bootsausstattung: Kein passender Zylinder erzeugt"))
    j.spawned=ident(spawned[1])
    assert(j.spawned,tr("Bootsausstattung: Erzeugter Zylinder nicht auffindbar"))
    j.waitUntil=now+8
    core.log(tr("Bootsausstattung: Zylinder erzeugt; warte auf Motoranschluss"))
end
function M.tick()
    local ok,err=pcall(tick)
    if not ok then
        core.log(tr("ERROR Bootsausstattung: ")..tostring(err),tr("Fehler"))
        if job then job.failed=job.failed+1 end
        finish(tr("Ausstattung abgebrochen"))
    end
end
return M
