-- One catalogue for item search and every package. Metadata only survives ticks.
-- Asset loading is opt-in and bounded; opening the menu never starts this scan.
local core=require("core")
local names=require("item_names")
local M={}
local scan,rows,components=nil,{},{}
local missing,seen={},{}
local known,lastDiscovery={},-math.huge
local revision,ready,unloaded=0,false,0
local state="Noch nicht geladen"
local function read(o,k) local ok,v=pcall(function() return o[k] end);if ok then return v end end
local function path(o) return core.fullName(o):match("^%S+%s+(/.+)$") end
local function visit(item,seen,depth)
    local p=path(item)
    if not p or seen[p] or depth>16 then return end
    seen[p]=true
    local packages=require("features.packages")
    local player,vault=packages.eligible(item,1),packages.eligible(item,2)
    if player or vault then
        local name,search=names.describe(read(item,"Name"),p)
        rows[#rows+1]={path=p,name=name,lname=names.normalize(name),search=search,
            cat=read(item,"Category") or 0,player=player,vault=vault}
    end
    local map=read(item,"Components")
    if map then pcall(function() map:ForEach(function(k)
        local c=core.unwrap(k);local cp=path(c)
        if cp then components[cp]=true;visit(c,seen,depth+1) end
    end) end) end
end
function M.start(force,retryMissing,discoverNew)
    if scan then return end
    local paths
    if ready and not force then
        paths={}
        local queued={}
        if retryMissing then for _,p in ipairs(missing) do paths[#paths+1]=p;queued[p]=true end end
        if discoverNew and os.clock()-lastDiscovery>=5 then
            for _,p in ipairs(require("features.packages").paths()) do
                if not known[p] and not seen[p] and not queued[p] then paths[#paths+1]=p;queued[p]=true end
                known[p]=true
            end
            lastDiscovery=os.clock()
        end
        if #paths==0 then return end
        -- Explicit package requests retry missing entries without discarding the
        -- successful catalog. Ordinary UI refreshes never restart asset loading.
    else
        rows,components,seen,known={},{},{},{}
        paths=require("features.packages").paths()
        for _,p in ipairs(paths) do known[p]=true end
        lastDiscovery=os.clock()
    end
    missing={}
    ready=false
    scan={paths=paths,index=1,seen=seen,failed={},attempt=1,pc=core.address(core.pc())}
    revision=revision+1
    state="Katalog wird geladen …"
end
function M.refresh() M.start(false,true,true) end
function M.tick()
    if not scan then return end
    if core.address(core.pc())~=scan.pc then M.reset();return end
    local started=os.clock()
    for _=1,8 do
        local p=scan.paths[scan.index]
        if not p then
            if #scan.failed>0 and scan.attempt==1 then
                scan.paths=scan.failed;scan.failed={};scan.index=1;scan.attempt=2
                state=string.format("%d fehlende Assets werden erneut geladen",#scan.paths)
                revision=revision+1;core.log("Katalog: "..state);return
            end
            table.sort(rows,function(a,b) if a.lname==b.lname then return a.path<b.path end;return a.lname<b.lname end)
            missing=scan.failed
            state=string.format("%d inventarfaehige Arten; %d nicht geladen",#rows,#missing)
            unloaded=#missing;ready=true;scan=nil;revision=revision+1;core.log("Katalog: "..state);return
        end
        local item,why,detail=require("features.packages").load(p)
        if item then visit(item,scan.seen,0) else
            scan.failed[#scan.failed+1]=p
            -- Bounded diagnostics: enough to identify missing assets without flooding the log.
            if scan.attempt==2 and #scan.failed<=10 then
                core.log("Katalog: Asset fehlt: "..p.." ("..tostring(why).."; "..tostring(detail)..")","Warnung")
            end
        end
        scan.index=scan.index+1
        if os.clock()-started>=0.003 then break end
    end
    state=string.format("Katalog: %d / %d, %d Arten",scan.index-1,#scan.paths,#rows)
    revision=revision+1
end
function M.snapshot() return rows,components,ready,revision,state,unloaded end
function M.reset() scan=nil;rows={};components={};missing={};seen={};known={};lastDiscovery=-math.huge;ready=false;unloaded=0;revision=revision+1;state="Noch nicht geladen" end
return M
