-- One catalogue for item search and every package. Metadata only survives ticks.
-- Asset loading is opt-in and bounded; opening the menu never starts this scan.
local core=require("core")
local M={}
local scan,rows,components=nil,{},{}
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
        local name=core.str(read(item,"Name"))
        if not name or name=="" then name=p:match("%.([^%.]+)$") or p end
        rows[#rows+1]={path=p,name=name,lname=name:lower(),cat=read(item,"Category") or 0,player=player,vault=vault}
    end
    local map=read(item,"Components")
    if map then pcall(function() map:ForEach(function(k)
        local c=core.unwrap(k);local cp=path(c)
        if cp then components[cp]=true;visit(c,seen,depth+1) end
    end) end) end
end
function M.start(force)
    if scan or (ready and not force) then return end
    rows,components={},{}
    ready=false
    scan={paths=require("features.packages").paths(),index=1,seen={},failed=0,pc=core.address(core.pc())}
    revision=revision+1
    state="Katalog wird geladen …"
end
function M.tick()
    if not scan then return end
    if core.address(core.pc())~=scan.pc then M.reset();return end
    local started=os.clock()
    for _=1,8 do
        local p=scan.paths[scan.index]
        if not p then
            table.sort(rows,function(a,b) if a.lname==b.lname then return a.path<b.path end;return a.lname<b.lname end)
            state=string.format("%d inventarfaehige Arten; %d nicht geladen",#rows,scan.failed)
            unloaded=scan.failed;ready=true;scan=nil;revision=revision+1;core.log("Katalog: "..state);return
        end
        local item,why=require("features.packages").load(p)
        if item then visit(item,scan.seen,0) elseif why=="load" then scan.failed=scan.failed+1 end
        scan.index=scan.index+1
        if os.clock()-started>=0.003 then break end
    end
    state=string.format("Katalog: %d / %d, %d Arten",scan.index-1,#scan.paths,#rows)
    revision=revision+1
end
function M.snapshot() return rows,components,ready,revision,state,unloaded end
function M.reset() scan=nil;rows={};components={};ready=false;unloaded=0;revision=revision+1;state="Noch nicht geladen" end
return M
