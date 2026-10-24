-- Compress only the remaining TIME of already admitted crafting jobs.
-- Native fabrication still consumes materials/energy and delivers the item.
-- No Finish callbacks, queue edits, forced unpausing or shared-recipe mutations.
-- Direct float-property writes avoid UFunction struct marshalling entirely.
local core=require("core")
local M={}
local enabled=false
local buildEnabled=false
local message="Aus"
local nextScan=0
local function call(o,fn,...)
    if not core.isValid(o) then return nil end
    local args=table.pack(...)
    local ok,v=pcall(function() return o[fn](o,table.unpack(args,1,args.n)) end)
    if ok then return v end
end
local function read(o,key)
    local ok,v=pcall(function() return o[key] end)
    if ok then return v end
end
local function finite(v) return type(v)=="number" and v==v and math.abs(v)<math.huge end
local function same(a,b) return core.isValid(a) and core.isValid(b) and core.address(a)==core.address(b) end
local function world(o) return read(call(o,"GetLevel"),"OwningWorld") end
local function arrayLength(q)
    if type(q)=="table" then return #q end
    local ok,n=pcall(function() return q:GetArrayNum() end)
    if ok and finite(n) and n>=0 and n<=4096 then return n end
    return 0
end
function M.setEnabled(on)
    enabled=on==true
    message=enabled and "Aktiv: Inventar und Fabrikatoren bis 50 m" or "Aus"
    nextScan=0
    core.log("Instant Craft: "..message)
end
function M.setBuildEnabled(on)
    buildEnabled=on==true
    nextScan=0
    core.log("Instant Build: "..(buildEnabled and "Aktiv, eigene Bauauftraege" or "Aus"))
end
function M.status() return enabled,message end
function M.onWorldChanged() enabled,buildEnabled,nextScan=false,false,0;message="Aus" end
function M.tick()
    if not enabled and not buildEnabled then return end
    -- One scan per second, never per frame; do not retain unrooted UObjects.
    if os.clock()<nextScan then return end
    nextScan=os.clock()+1
    local pawn=core.pawn()
    if call(pawn,"HasAuthority")~=true then return end
    local pw=world(pawn)
    if not core.isValid(pw) then return end
    local ok,list=pcall(FindAllOf,"VoyageFabricatorComponent")
    if not ok or type(list)~="table" then return end
    local shortened,builds,outputs=0,0,0
    local x,y,z=core.location(pawn)
    for _,fab in ipairs(list) do
        local owner=call(fab,"GetOwner")
        local a,b,c=core.location(owner)
        local near=finite(x) and finite(y) and finite(z) and finite(a) and finite(b) and finite(c)
            and (x-a)^2+(y-b)^2+(z-c)^2<=5000^2
        local scoped=same(world(owner),pw) and (same(owner,pawn) or near) and call(owner,"HasAuthority")==true
            and call(owner,"IsActorBeingDestroyed")==false
        -- OutputQueue holds finished, already paid inventory products. Native
        -- delivery remains in charge; shorten its delay without adding items.
        if scoped and enabled and call(fab,"IsPaused")==false then
            local delay=read(fab,"OutputTimer")
            if finite(delay) and delay>0.01 and arrayLength(read(fab,"OutputQueue"))>0 then
                if pcall(function() fab.OutputTimer=0.001 end) then outputs=outputs+1 end
            end
        end
        if scoped and call(fab,"IsPaused")==false
            and call(fab,"IsFabricating")==true then
            local max,remaining=read(fab,"ProgressTimerMax"),read(fab,"ProgressTimerRemaining")
            -- Native QueueItem increments CurrentFabricationId AFTER enqueue.
            -- JoinModuleUpdate processes ItemQueue[0], not that next-ID counter.
            -- Check length BEFORE indexing: this UE4SS grows out-of-range arrays
            -- even for reads. Never touch ReservedItems (soft-pointer keys).
            local queue=read(fab,"ItemQueue")
            local count=arrayLength(queue)
            local item
            if finite(count) and count>0 and count<=4096 then
                local got,entry=pcall(function() return queue[1] end)
                if got then item=read(entry,"Item") end
            end
            local isBuild=call(item,"IsBuildable")==true
            local ownBuild=isBuild and same(call(owner,"GetOwner"),pawn)
                and read(owner,"IsBlocked")==false
            if ((enabled and not isBuild) or (buildEnabled and ownBuild))
                and call(item,"IsCraftable")==true
                and finite(max) and finite(remaining) and max>0.05 and remaining>0.05 and remaining<=max then
                local target=math.max(0.001,0.05*remaining/max)
                local changed=pcall(function()
                    fab.ProgressTimerMax=0.05
                    fab.ProgressTimerRemaining=target
                end)
                if changed then
                    shortened=shortened+1
                    if isBuild then builds=builds+1 end
                end
            end
        end
    end
    if shortened>0 or outputs>0 then
        message=string.format("%d Herstellung, %d Bau, %d Ausgaben beschleunigt",shortened-builds,builds,outputs)
        core.log("Instant: "..message.."; Abschluss durch das Spiel")
    end
end
function M.addToPage(ui,page,card)
    ui.toggleRow(page,card,"Instant Craft",function() return enabled end,M.setEnabled,
        "Inventar und Fabrikatoren bis 50 m; Material- und Energiebedarf gelten")
    ui.toggleRow(page,card,"Instant Build",function() return buildEnabled end,M.setBuildEnabled,
        "Eigene platzierte Bauplaene bis 50 m; nur bei freier Bauposition")
    ui.infoRow(page,card,"Instant Craft",function() return message end)
end
return M
