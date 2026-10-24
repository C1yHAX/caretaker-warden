local core=require("core")
local M={}
local CLASS="/Game/Blueprints/AI/Characters/CarrierBot/CarrierBot.CarrierBot_C"
-- Original ToggleCarrierBotFollowMode: nearest CarrierBot, SetState(4 / 0).
-- One explicit click, no polling; keep the action within 100 m of this player.
function M.follow(on)
    local pawn=core.pawn();local x,y,z=core.location(pawn)
    if not x then return false,"Kein Spieler" end
    local best,target=10000^2,nil
    for _,bot in ipairs(core.actorsOf(CLASS)) do
        local a,b,c=core.location(bot)
        if a then
            local d=(x-a)^2+(y-b)^2+(z-c)^2
            if d<best then target,best=bot,d end
        end
    end
    if not target then return false,"Kein Traegerroboter innerhalb von 100 m" end
    local ok,yes=pcall(function()
        if not target:HasAuthority() or target:IsActorBeingDestroyed() then return false end
        local state=on and 4 or 0
        target:SetState(state,nil,core.vec(0,0,0))
        return target.State==state or target.QueuedState==state
    end)
    return ok and yes==true,ok and yes==true and (on and "Traegerroboter folgt" or "Traegerroboter angehalten") or "Roboterbefehl nicht bestaetigt"
end
function M.addToPage(ui,page,parent)
    local card=ui.card(parent,"Traegerroboter","Naechster Roboter bis 100 m")
    local function run(on) return function() local ok,msg=M.follow(on);ui.toast(msg,ok and "good" or "warn") end end
    ui.buttonGrid(card,2,{{"Folgen",run(true)},{"Anhalten",run(false)}})
end
return M
