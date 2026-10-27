local tr = require("i18n").t
-- One-shot, world-scoped resource refill. All entry points run on the game thread.
-- Inspect every module component of nearby module actors, including detached
-- batteries. No boat membership, resource-name guessing or TMap writes.
local core = require("core")
local M = {}
local MODULE = "/Script/Voyage.VoyageModuleComponent"
local RANGES = { 10, 25, 50, 100 }
local rangeIndex, status = 3, tr("Noch nicht aufgefuellt")
M.resources = {
    { 0, tr("Batterien aufladen") }, { 16, tr("Dieseltanks befuellen") },
    { 1, tr("Benzintanks befuellen") }, { 10, tr("Methantanks befuellen") },
    { 2, tr("Oeltanks befuellen") }, { 4, tr("Frischwassertanks befuellen") },
    { 3, tr("Salzwassertanks befuellen") }, { 11, tr("Sauerstofftanks befuellen") },
    { 17, tr("CO2-Tanks befuellen") }, { 12, tr("Dampfspeicher befuellen") },
}
local function call(o, fn, ...)
    if not core.isValid(o) then return nil end
    local args = table.pack(...)
    local ok, value = pcall(function() return o[fn](o, table.unpack(args,1,args.n)) end)
    if ok then return value end
end
local function finite(v) return type(v)=="number" and v==v and math.abs(v)<math.huge end
local function world(o)
    local level = call(o,"GetLevel")
    if not core.isValid(level) then return nil end
    local ok,w = pcall(function() return level.OwningWorld end)
    return ok and core.isValid(w) and core.address(w) or nil
end
function M.fillModule(module, resource)
    if call(module,"IsA",MODULE)~=true then return "skip" end
    -- GetResourceAmount returns zero for disabled modules, even if their stored
    -- resource map is nonempty. Do not mistake that masked reading for empty.
    if call(module,"IsDisabled")~=false then return "skip" end
    -- Capacity alone is insufficient: shared containers can report it for an
    -- unrelated resource. A non-primary resource must already be stored here.
    local current = call(module,"GetResourceAmount",resource)
    local maximum = call(module,"GetMaxResourceAmount",resource)
    local primary = call(module,"GetPrimaryResourceType")
    if not finite(current) or not finite(maximum) then return "error" end
    if maximum<=0 or current<0 or (primary~=resource and current<=0) then return "skip" end
    if current>=maximum then return "full" end
    call(module,"ForceAddResource",resource,maximum-current)
    local after = call(module,"GetResourceAmount",resource)
    if finite(after) and after>=maximum-math.max(1e-6,maximum*1e-6) then return "filled" end
    return "error"
end
function M.fill(resource)
    local allowed=false
    for _,r in ipairs(M.resources) do if r[1]==resource then allowed=true end end
    if not allowed then return false,tr("Unbekannte Ressource") end
    local pawn=core.pawn()
    local w=world(pawn)
    local x,y,z=core.location(pawn)
    if not w or not finite(x) or not finite(y) or not finite(z) then return false,tr("Kein Spieler in einer Welt") end
    if call(pawn,"HasAuthority")~=true then return false,tr("Nur der Host kann Speicher auffuellen") end
    local cls=core.find(MODULE)
    if not cls then return false,tr("Modulklasse nicht verfuegbar") end
    local totals={filled=0,full=0,error=0,skip=0}
    local seen={}
    for _,actor in ipairs(core.actorsOf("/Script/Voyage.VoyageModuleActor")) do
        local a,b,c=core.location(actor)
        if world(actor)==w and call(actor,"IsActorBeingDestroyed")==false and call(actor,"HasAuthority")==true
            and finite(a) and finite(b) and finite(c) and (a-x)^2+(b-y)^2+(c-z)^2<=(RANGES[rangeIndex]*100)^2 then
            local modules=core.outList("storage components",function() return actor:K2_GetComponentsByClass(cls) end)
            for _,module in ipairs(modules) do
                local id=core.address(module)
                if id and not seen[id] then
                    seen[id]=true
                    local result=M.fillModule(module,resource)
                    totals[result]=totals[result]+1
                    if result=="filled" or result=="error" then
                        core.log("Storage: "..core.shortName(actor).." resource="..resource.." result="..result)
                    end
                end
            end
        end
    end
    status=string.format(tr("%d aufgefuellt, %d bereits voll, %d Fehler (%d m)"),totals.filled,totals.full,totals.error,RANGES[rangeIndex])
    if totals.filled+totals.full+totals.error==0 then status=tr("Keine passenden Speicher im ")..RANGES[rangeIndex]..tr("-m-Umkreis") end
    core.log("Storage: "..status)
    return totals.filled+totals.full>0 and totals.error==0,status
end
function M.addToPage(ui,page,parent)
    local card=ui.card(parent,tr("Speicher in der Umgebung"))
    ui.stepperRow(page,card,tr("Umkreis"),{values=RANGES,index=function() return rangeIndex end,
        format=function(v) return v.." m" end,
        set=function(i) if RANGES[i] then rangeIndex=i end end})
    local buttons={}
    for _,row in ipairs(M.resources) do
        local resource=row[1]
        buttons[#buttons+1]={row[2],function() local ok,msg=M.fill(resource);ui.toast(msg,ok and "good" or "warn") end}
    end
    ui.buttonGrid(card,2,buttons)
    ui.infoRow(page,card,tr("Ergebnis"),function() return status end)
    ui.add(card,ui.paragraph(tr("Passende Speicher und Modul-Puffer im Umkreis; auch ohne Verbindung zum Boot.")))
end
return M
