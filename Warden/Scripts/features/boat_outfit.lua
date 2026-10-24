-- Original engine retrofit geometry and item spawning, with explicit socket type
-- and cylinder identity checks. BP_Module_Crafter calls the SAME native
-- SpawnActorForItem as SetBoatEnginesLevel, without Lua soft-pointer marshalling.
local core=require("core")
local M={}
local ENGINE="/Script/Voyage.VoyageModuleEngineActor"
local SNAP="/Script/Voyage.VoyagePhysicalSnapSocketComponent"
local PREFIX="/Game/Blueprints/Modules/Utility/Boat/"
local variants={DieselEngine={37,61,60,62},ElectricEngine={46,64,63,65}}
local names={DieselEngine="Diesel",ElectricEngine="Electric"}
local job
local status="Noch nicht geprueft"
local function read(o,k) local ok,v=pcall(function() return o[k] end);if ok then return v end end
local function call(o,k,...)
    if not core.isValid(o) then return end
    local a=table.pack(...);local ok,v=pcall(function() return o[k](o,table.unpack(a,1,a.n)) end)
    if ok then return v end
end
local function same(a,b) return core.isValid(a) and core.isValid(b) and core.address(a)==core.address(b) end
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
        status=string.format("%s: %d verbunden, %d uebersprungen, %d unbestaetigt",reason,j.connected,j.skipped,j.failed)
        j.report(status,j.failed==0 and j.skipped==0 and j.connected>0 and j.index>#j.plan)
    end
end
local function scan(boat)
    local plan,seen,omitted={},{},0
    local stats={engines=0,components=0,diesel=0,electric=0,occupied=0,unknown=0}
    local attached=core.outList("boot engines",function(h) return boat:GetAttachedActors(h,true,true) end,"OutActors")
    for _,actor in ipairs(attached) do
        if isa(actor,ENGINE) and belongs(actor,boat) then
            stats.engines=stats.engines+1
            for _,comp in ipairs(array(call(actor,"K2_GetComponentsByClass",core.find(SNAP)))) do
                stats.components=stats.components+1
                local kind=core.str(read(comp,"SocketTypeOverride"))
                local plug=call(comp,"IsPlugSocket")
                local sockets=array(read(comp,"Sockets"))
                core.log(string.format("Bootsanalyse: %s; Typ=%s; Stecker=%s; Anschluesse=%d",
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
    status=string.format("%d Motoren; %d Diesel / %d Elektro; %d belegt; %d fremde Verbindungen",
        stats.engines,stats.diesel,stats.electric,stats.occupied,stats.unknown)
    core.log("Bootsanalyse: "..status..string.format("; %d Anbauteile; %d Anschlusskomponenten",#attached,stats.components))
    return plan,omitted
end
function M.status() return status end
function M.inspect(boat)
    if not core.isValid(boat) or call(boat,"IsActorBeingDestroyed")~=false then return false,"Kein gueltiges Zielboot" end
    local plan=scan(boat)
    return #plan>0,status
end
function M.start(boat,level,report)
    if job then return false,"Ausstattung laeuft bereits" end
    if level<1 or level>4 or level%1~=0 or call(boat,"HasAuthority")~=true then return false,"Kein gueltiges Zielboot" end
    local plan,omitted=scan(boat)
    if #plan==0 then return false,"Keine passenden Motoranschluesse: "..status end
    job={boat=ident(boat),pc=core.address(core.pc()),plan=plan,index=1,level=level,report=report,connected=0,skipped=omitted,failed=0}
    return true,string.format("%d Motoranschluesse werden einzeln ausgeruestet",#plan)
end
function M.cancel() if job then finish("Ausstattung beendet") end end
function M.onWorldChanged() job=nil;status="Noch nicht geprueft" end
local function tick()
    local j=job;if not j then return end
    if j.pc~=core.address(core.pc()) then job=nil;return end
    local boat=resolve(j.boat)
    if not boat or call(boat,"HasAuthority")~=true or call(boat,"IsActorBeingDestroyed")~=false then finish("Zielboot nicht mehr verfuegbar");return end
    local row=j.plan[j.index]
    if not row then finish("Bootsausstattung fertig");return end
    local engine,comp,socket=resolve(row.engine),resolve(row.component),resolve(row.socket)
    if not engine or not comp or not socket or not belongs(engine,boat)
        or not same(read(socket,"Owner"),comp) or not same(call(comp,"GetOwner"),engine)
        or call(engine,"HasAuthority")~=true then
        j.skipped=j.skipped+1;j.waitUntil=nil;j.index=j.index+1;return
    end
    local existing=linked(socket)
    if j.waitUntil then
        if cylinder(existing,row.kind) and core.address(existing)~=j.old then
            j.connected=j.connected+1;j.waitUntil=nil;j.index=j.index+1
            status=string.format("%d/%d Motoranschluesse verbunden",j.connected,#j.plan)
            core.log("Bootsausstattung: "..status)
        elseif os.clock()>=j.waitUntil then
            j.failed=j.failed+1
            core.log("Bootsausstattung: Zylinder erzeugt, Anschluss nicht bestaetigt", "Warnung")
            finish("Einrasten unbestaetigt; weitere Wechsel gestoppt")
        end
        return
    end
    -- A hull, engine, CO2 outlet or unknown connection is NEVER removed.
    local plugged=call(socket,"IsPlugged")
    if type(plugged)~="boolean" or (plugged and not cylinder(existing,row.kind))
        or (not plugged and core.isValid(existing)) then
        j.skipped=j.skipped+1;j.index=j.index+1;return
    end
    local km=core.lib("math")
    local t=call(comp,"K2_GetComponentToWorld")
    local relative=read(socket,"RelativeLocation")
    local pos=call(km,"TransformLocation",t,relative)
    local x,y,z=core.xyz(pos)
    if not x then j.failed=j.failed+1;j.index=j.index+1;return end
    -- Same initial orientation/offset as the shipped SetBoatEnginesLevel.
    if row.kind=="ElectricEngine" then z=z+50 end
    local transform=call(km,"MakeTransform",core.vec(x,y,z),core.rot(0,row.kind=="ElectricEngine" and 180 or 0,0),core.vec(1,1,1))
    if not transform then j.failed=j.failed+1;j.index=j.index+1;return end
    local old=core.address(existing)
    local persistent=call(core.lib("subsystem"),"GetWorldSubsystem",boat,core.find("/Script/Voyage.VoyagePersistentSubsystem"))
    if core.isValid(existing) and not core.isValid(persistent) then
        j.failed=j.failed+1;j.index=j.index+1;return
    end
    local ok,msg,crafter=require("features.spawn").craft({value=variants[row.kind][j.level],label="Motorzylinder"},transform,engine)
    if not ok then j.failed=j.failed+1;j.index=j.index+1;core.log(msg,"Fehler");return end
    if core.isValid(existing) then
        -- Revalidate after preparing the crafter. Delete ONLY the typed cylinder
        -- still connected to this exact engine socket; never a socket's owner.
        local current=linked(socket)
        if same(current,existing) and cylinder(existing,row.kind) and not same(existing,boat) and not same(existing,engine) then
            local removed=pcall(function() persistent:DestroyActor(existing,0.0) end)
            if not removed then
                call(crafter,"K2_DestroyActor")
                j.failed=j.failed+1;j.index=j.index+1;return
            end
        else
            call(crafter,"K2_DestroyActor")
            j.skipped=j.skipped+1;j.index=j.index+1;return
        end
    end
    j.old=old;j.waitUntil=os.clock()+8
end
function M.tick()
    local ok,err=pcall(tick)
    if not ok then
        core.log("ERROR Bootsausstattung: "..tostring(err),"Fehler")
        if job then job.failed=job.failed+1 end
        finish("Ausstattung abgebrochen")
    end
end
return M
