-- Super strength lightens ONLY the currently held rigid body. Never amplify
-- MassGrabStrength: the native grabber uses it for body mass and reaction force.
-- Original scale is restored on release, disabling, pawn/world change or failure.
local core = require("core")
local M = {}
local saved
local CLASS = "/Script/Engine.PrimitiveComponent"
local function call(o, name, ...)
    if not core.isValid(o) then return nil end
    local args=table.pack(...)
    local ok,v=pcall(function() return o[name](o,table.unpack(args,1,args.n)) end)
    if ok then return v end
    return nil
end
local function read(o,k)
    local ok,v=pcall(function() return o[k] end)
    if ok then return v end
    return nil
end
local function finite(v) return type(v)=="number" and v==v and math.abs(v)<math.huge end
local function close(a,b) return finite(a) and finite(b) and math.abs(a-b)<=math.max(1e-8,math.abs(b)*1e-5) end
local function id(o)
    if call(o,"IsA",CLASS)~=true then return nil end
    local name=core.fullName(o)
    local path=name:match("^%S+%s+(/.+)$")
    local address=core.address(o)
    if not path or path:find("Default__",1,true) or path:sub(1,8)=="/Script/" or not address then return nil end
    return {path=path,name=name,address=address}
end
local function restore()
    if not saved then return true end
    local ok,o=pcall(StaticFindObject,saved.id.path)
    if not ok then return false end
    local current=id(o)
    if not current or current.name~=saved.id.name or current.address~=saved.id.address then saved=nil;return true end
    local bone=FName(saved.bone,1)
    local scale=call(o,"GetMassScale",bone)
    if not finite(scale) then return false end
    -- A later native release or another mod wins over our snapshot.
    if close(scale,saved.applied) then
        call(o,"SetMassScale",bone,saved.before)
        if not close(call(o,"GetMassScale",bone),saved.before) then return false end
    end
    saved=nil
    return true
end
function M.pending() return saved~=nil end
function M.tick(grabber,enabled)
    local body,bone,identity
    if enabled and call(grabber,"IsGrabbing")==true then
        body=read(grabber,"GrabbedComponent")
        identity=id(body)
        bone=core.str(read(grabber,"GrabbedComponentBoneName"))
    end
    if saved and (not identity or identity.address~=saved.id.address or identity.name~=saved.id.name or bone~=saved.bone) then
        if not restore() then return false end
    end
    if not identity or not bone then return true end
    if saved then return true end
    local boneName=FName(bone,1)
    if call(body,"IsSimulatingPhysics",boneName)~=true then return true end
    local mass,scale=call(body,"GetMass"),call(body,"GetMassScale",boneName)
    if not finite(mass) or mass<=0 or not finite(scale) or scale<=0 then return false end
    -- 50 kg is below the native grabber's ordinary 100 strength. Normal props
    -- remain unchanged; objects return to their original mass when released.
    if mass<=50 then return true end
    local target=scale*50/mass
    if not finite(target) or target<=0 then return false end
    saved={id=identity,bone=bone,before=scale,applied=target}
    call(body,"SetMassScale",boneName,target)
    local after=call(body,"GetMass")
    if not close(call(body,"GetMassScale",boneName),target) or not finite(after) or after>50.1 then
        restore();return false
    end
    return true
end
return M
