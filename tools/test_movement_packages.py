"""Stateful regression tests: real Lua modules; no game launch or native simulation."""
from pathlib import Path
import unittest
from lupa.lua54 import LuaRuntime

ROOT = Path(__file__).resolve().parent.parent


class Features(unittest.TestCase):
    def setUp(self):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua.execute(f'package.path = "{(ROOT / "Warden/Scripts").as_posix()}/?.lua;" .. package.path')
        self.lua.execute('''
          local id = 0
          function obj(fields)
            id = id + 1; fields.id = id
            function fields:IsValid() return not self.dead end
            function fields:GetAddress() return self.id end
            function fields:GetFullName() return "VoyageItem " .. (self.path or ("/World/Object" .. self.id)) end
            return fields
          end
          registry, inventoryCounts, logs, keys = {}, {}, {}, {}
          capacity = 100000
          inv = obj({})
          function inv:GetNumItems(item) return inventoryCounts[item.path] or 0 end
          function inv:AddItem(item, data)
            local n = math.min(capacity, data.ItemCount)
            inventoryCounts[item.path] = self:GetNumItems(item) + n
            return n
          end
          cmc = obj({MaxWalkSpeed=600, MaxWalkSpeedCrouched=300, MaxAcceleration=2048,
            MaxFlySpeed=600, JumpZVelocity=420, bCheatFlying=false, MovementMode=1})
          function cmc:StopMovementImmediately() end
          function cmc:SetMovementMode(mode) self.MovementMode=mode end
          function capsule(mode)
            local c = obj({mode=mode})
            function c:GetCollisionEnabled() return self.mode end
            function c:SetCollisionEnabled(v) self.mode=v end
            return c
          end
          dynamic = obj({active=true})
          function dynamic:IsActive() return self.active end
          function dynamic:SetActive(v) self.active=v end
          pawn = obj({CapsuleComponent=capsule(2),CollisionCylinderPhysical=capsule(3),
            VoyageDynamicCollision=dynamic,collision=true, x=0,y=0,z=0})
          function pawn:GetActorEnableCollision() return self.collision end
          function pawn:SetActorEnableCollision(v) self.collision=v end
          function pawn:K2_AddActorWorldOffset(v, sweep)
            self.x=self.x+v.X; self.y=self.y+v.Y; self.z=self.z+v.Z; self.sweep=sweep
          end
          pc = obj({})
          world = obj({})
          function pc:IsInputKeyDown(k) return keys[k.KeyName] == true end
          function pc:GetInputAnalogKeyState() return 0 end
          function pc:GetControlRotation() return {pitch=0,Yaw=0,Roll=0} end
          gameplay = {GetWorldDeltaSeconds=function() return 1/60 end}
          FName = function(s) return s end
          local core = {
            isValid=function(o) return type(o)=='table' and o.id ~= nil and not o.dead end,
            address=function(o) return o and o.id end,
            fullName=function(o) return o and o.GetFullName and o:GetFullName() or "?" end,
            str=function(v) return v end,
            unwrap=function(o) return o and o.get and o:get() or o end,
            find=function(path) return registry[path] end,
            inventory=function() return inv end,
            character=function() return pawn, pawn and cmc or nil end,
            pc=function() return pc end,
            safe=function(_, fn) return pcall(fn) end,
            lib=function(name)
              if name=='gameplay' then return gameplay end
              if name=='misc' then return {GetActorWorld=function() return world end} end
            end,
            outList=function(_, fn, name) local h={} local r=fn(h); return type(r)=='table' and r or h[name] or h end,
            vec=function(x,y,z) return {X=x,Y=y,Z=z} end,
            log=function(s) logs[#logs+1]=s end,
          }
          package.loaded.core=core
          LoadAsset=function(path) return registry[path] end
          FindAllOf=function() return {} end
          LoopInGameThreadAfterFrames=function(_, fn) frame=fn; return 42 end
          CancelDelayedAction=function() cancelled=true end
          package.loaded['data.item_paths']={}
          function item(path, cat, inventory, components)
            local o = obj({path=path,Name=path,Category=cat,bSupportInventory=inventory,
              bOnlyAllowDesiredInventory=false, BlockedInventoryTypes={}, Components={}})
            function o:IsA() return true end
            function o.Components:ForEach(fn)
              for _, k in ipairs(components or {}) do fn({get=function() return k end}, {get=function() return 2 end}) end
            end
            registry[path]=o
            return o
          end
          function finish(p)
            for _=1,1000 do if not p.busy() then return end; p.tick() end
            error('package never finished')
          end
        ''')

    def test_speed_reapplication_not_compounded_and_restored(self):
        self.lua.execute('''
          local m=require('features.movement')
          m.setIndex('walk',4); assert(cmc.MaxWalkSpeed==1200 and cmc.MaxAcceleration==4096)
          m.frame(); assert(cmc.MaxWalkSpeed==1200)
          cmc.MaxWalkSpeed=600; m.frame(); assert(cmc.MaxWalkSpeed==1200)
          m.setIndex('walk',2); assert(cmc.MaxWalkSpeed==600 and cmc.MaxAcceleration==2048)
        ''')

    def test_flight_factor_changes_actual_displacement(self):
        self.lua.execute('''
          local m=require('features.movement'); keys.W=true
          m.setFly(true); local a=pawn.x; assert(a==10 and pawn.sweep)
          m.setIndex('fly',3); assert(pawn.x-a==40)
          m.setFly(false); assert(cmc.MovementMode==3 and not cmc.bCheatFlying)
        ''')

    def test_real_reflection_pitch_and_failure_restore(self):
        self.lua.execute('''
          local m=require('features.movement'); keys.W=true
          function pc:GetControlRotation() return {pitch=90,Yaw=0,Roll=0} end
          m.setFly(true); assert(math.abs(pawn.z-10)<0.001)
          function pc:GetControlRotation() return {} end
          m.frame(); assert(not m.state.fly and cmc.MovementMode==3 and not cmc.bCheatFlying)
          assert(cancelled and #logs==1)
          m.tick(); assert(#logs==1)
        ''')

    def test_failure_before_first_flight_never_disables_walking(self):
        self.lua.execute('''
          local m=require('features.movement')
          function pc:GetControlRotation() return {pitch=0/0,Yaw=0} end
          m.setFly(true); assert(cmc.MovementMode==1 and frame==nil and not m.state.fly)
        ''')

    def test_offset_error_restores_noclip_collision_and_movement(self):
        self.lua.execute('''
          local m=require('features.movement'); keys.W=true
          function pawn:K2_AddActorWorldOffset() error('offset failure') end
          m.setNoclip(true)
          assert(not m.state.noclip and not m.state.fly and pawn.collision and dynamic.active)
          assert(cmc.MovementMode==3 and pawn.CapsuleComponent.mode==2)
        ''')

    def test_changing_flight_speed_while_grounded_does_not_start_a_loop(self):
        self.lua.execute('''
          local m=require('features.movement'); m.setIndex('fly',4)
          assert(frame==nil and cmc.MaxFlySpeed==600 and cmc.MovementMode==1)
          keys.W=true; m.setFly(true); assert(pawn.x==80)
          m.setFly(false); assert(cancelled and cmc.MaxFlySpeed==600)
        ''')

    def test_noclip_disables_both_capsules_and_restores_actual_modes(self):
        self.lua.execute('''
          local m=require('features.movement'); keys.W=true; m.setNoclip(true)
          assert(pawn.CapsuleComponent.mode==0 and pawn.CollisionCylinderPhysical.mode==0)
          assert(not dynamic.active and not pawn.collision and not pawn.sweep)
          m.setNoclip(false)
          assert(pawn.CapsuleComponent.mode==2 and pawn.CollisionCylinderPhysical.mode==3)
          assert(dynamic.active and pawn.collision and pawn.sweep and m.state.fly)
        ''')

    def test_world_reset_drops_old_objects(self):
        self.lua.execute('''
          local m=require('features.movement'); m.setIndex('walk',4)
          local old=cmc; m.onWorldChanged(); pawn=nil; m.tick()
          assert(old.MaxWalkSpeed==1200) -- no dereference/restore into the old world
        ''')

    def test_flight_respects_disabled_input_and_open_menu_setting(self):
        self.lua.execute('''
          local m=require('features.movement'); keys.W=true
          package.loaded.ui={isOpen=true,walkWhileOpen=false}; m.setFly(true)
          assert(pawn.x==0)
          package.loaded.ui.walkWhileOpen=true; m.frame(); assert(pawn.x==10)
          function pc:IsMoveInputIgnored() return true end
          m.frame(); assert(pawn.x==10)
        ''')

    def test_frame_detects_world_change_before_main_watcher(self):
        self.lua.execute('''
          local m=require('features.movement'); m.setIndex('walk',4)
          local old=cmc
          old.dead=true; world=obj({}); pawn=nil
          m.frame(); assert(old.MaxWalkSpeed==1200)
        ''')

    def test_packages_complete_all_unloaded_inventory_types_only(self):
        self.lua.execute('''
          local a=item('/Game/A.A',2,true); local b=item('/Game/B.B',19,true)
          local c=item('/Game/C.C',18,false)
          local d=item('/Game/D.D',26,true); d.BlockedInventoryTypes={1}
          package.loaded['data.item_paths']={a.path,b.path,b.path,c.path,d.path}
          local p=require('features.packages'); assert(p.start('all',5)); finish(p)
          assert(inventoryCounts[a.path]==5 and inventoryCounts[b.path]==5)
          assert(inventoryCounts[c.path]==nil and inventoryCounts[d.path]==nil)
        ''')

    def test_parts_include_recipe_dependencies_and_all_part_variants(self):
        self.lua.execute('''
          local special=item('/Game/Special.Special',16,true)
          local part=item('/Game/Part.Part',19,true)
          local material=item('/Game/Material.Material',22,true)
          local recipe=item('/Game/Recipe.Recipe',18,false,{special})
          local trash=item('/Game/Trash.Trash',28,true)
          package.loaded['data.item_paths']={recipe.path,part.path,material.path,trash.path}
          local p=require('features.packages'); assert(p.start('parts',50)); finish(p)
          assert(inventoryCounts[special.path]==50 and inventoryCounts[part.path]==50)
          assert(inventoryCounts[material.path]==50 and inventoryCounts[trash.path]==nil)
        ''')

    def test_trash_selection_and_actual_partial_counts(self):
        self.lua.execute('''
          local trash=item('/Game/Trash.Trash',28,true); local part=item('/Game/Part.Part',19,true)
          package.loaded['data.item_paths']={part.path,trash.path}; capacity=3
          local p=require('features.packages'); assert(p.start('trash',50)); finish(p)
          assert(inventoryCounts[trash.path]==3 and inventoryCounts[part.path]==nil)
          assert(p.status():find('1 unvollständig',1,true))
        ''')

    def test_no_fake_success_on_void_return_or_zero_inventory_delta(self):
        self.lua.execute('''
          local a=item('/Game/A.A',19,true); inv.AddItem=function() return 50 end
          local p=require('features.packages'); local n=p.give(a,50,1); assert(n==0)
          inv.AddItem=function() end; n=p.give(a,50,1); assert(n==0)
        ''')

    def test_inventory_swap_cancels_package(self):
        self.lua.execute('''
          local a=item('/Game/A.A',19,true); package.loaded['data.item_paths']={a.path}
          local p=require('features.packages'); p.start('all',1); pc=obj({}); p.tick()
          assert(not p.busy() and inventoryCounts[a.path]==nil)
        ''')

    def test_missing_assets_and_vault_only_items_are_not_silently_complete(self):
        self.lua.execute('''
          local a=item('/Game/A.A',19,true)
          local v=item('/Game/V.V',19,true); v.bOnlyAllowDesiredInventory=true; v.DesiredInventory=1
          package.loaded['data.item_paths']={a.path,v.path,'/Game/Missing.Missing'}
          local p=require('features.packages'); local result
          p.start('all',1,function(_,success) result=success end); finish(p)
          assert(inventoryCounts[a.path]==1 and inventoryCounts[v.path]==nil)
          assert(result==false and p.status():find('1 Assets nicht geladen',1,true))
        ''')

    def test_manifest_contains_user_examples_and_igniter_variants(self):
        manifest = (ROOT / "Warden/Scripts/data/item_paths.lua").read_text(encoding="utf-8")
        for name in ("ConnectorPorts", "DisplayScreen", "BatteryCell", "DataStorageChip",
                     "AdvancedAlloyMesh", "ControlKnobsButtons", "StorageCylinder", "Part_Grenade_Ignition",
                     "Grenade_Ignition_Electric", "Grenade_Ignition_O2", "Grenade_Ignition_Petrol"):
            self.assertIn("DA_" + (name if "Ignition" in name else "Part_" + name), manifest)


if __name__ == "__main__":
    unittest.main()
