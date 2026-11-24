"""Repair visuals on previously healed objects and session-owned weather presets."""
import gzip
import json
import os
import unittest
from pathlib import Path

from lupa.lua54 import LuaRuntime
import test_inventory_repair as fixtures

ROOT = Path(__file__).resolve().parents[1]


class VisualRepair(unittest.TestCase):
    def setUp(self):
        fixture = fixtures.Repairs()
        fixture.setUp()
        self.lua = fixture.lua
        self.lua.execute("""
            IND='/Script/Voyage.VoyageDurabilityIndicatorComponent'
            H.classes[IND]=object('Class','IndicatorClass')
            function bindIndicator(actor, primary)
                local indicator=object(IND,'Indicator',{owner=actor})
                rawset(indicator,'DurabilityLast',1)
                rawset(indicator,'looksBroken',true)
                rawset(indicator,'UpdateDurability',function(self,v)
                    assert(v==1 and primary.Health==primary.DestructibleObjectProperties.Health)
                    self.looksBroken=false;self.DurabilityLast=v;updates=updates+1
                end)
                rawset(actor,'GetComponentByClass',function(self,cls)
                    if cls==H.classes[IND] then return indicator end
                    assert(cls==H.classes[DAMAGE]);return primary
                end)
                return indicator
            end
            updates=0
        """)

    def test_full_health_and_stale_material_on_three_panels(self):
        self.lua.execute("""
            local visuals={}
            for i,hp in ipairs({0,225,300}) do
                local actor,damage=target('Panel'..i,0,hp)
                damage.DestructibleObjectProperties.Health=300
                visuals[i]=bindIndicator(actor,damage)
            end
            assert(area.start())
            while area.busy() do
                local n=updates
                area.tick()
                assert(updates-n<=1)
            end
            assert(updates==3 and H.repairs==2)
            for _,v in ipairs(visuals) do assert(not v.looksBroken) end
        """)

    def test_secondary_component_and_foreign_indicator(self):
        self.lua.execute("""
            local actor,primary=target('Panel',0,20)
            local secondary=makeDamage(actor,99)
            local visual=bindIndicator(actor,primary)
            assert(area.damage(secondary,actor,100)=='fixed')
            assert(updates==0 and visual.looksBroken)
            visual.p.owner=H.pawn
            assert(area.damage(primary,actor,100)=='fixed' and updates==0)
        """)

    def test_boat_refreshes_healthy_module_once_even_if_shared(self):
        self.lua.execute("""
            local boat=makeBoat('A')
            local actor=object('ModuleActor','Attached',{level=H.level})
            attach(boat,actor)
            local damage=makeDamage(actor,100)
            local module=makeModule(actor,100,'noop',boat)
            module.p.DestructibleObjectReference=damage
            local visual=bindIndicator(actor,damage)
            repair();drain()
            assert(updates==1 and H.repairs==0 and not visual.looksBroken)
        """)


class Weather(unittest.TestCase):
    def setUp(self):
        lua = self.lua = LuaRuntime(unpack_returned_tuples=True)
        lua.execute(f'package.path={json.dumps((ROOT/"Warden/Scripts/?.lua").as_posix()+";")}..package.path')
        lua.execute("""
            registry={};actors={};host=true;world='one'
            function obj(path)
                local o={path=path}
                registry[path]=o
                function o:IsValid() return not self.gone end
                function o:IsActorBeingDestroyed() return self.gone==true end
                function o:K2_DestroyActor() self.gone=true end
                return o
            end
            pawn=obj('/World.Pawn');pc=obj('/World.PC')
            function pawn:GetLevel() return {OwningWorld=registry[world]} end
            function pawn:K2_GetActorLocation() return {} end
            function pawn:HasAuthority() return host end
            obj('one');obj('two')
            mathlib={MakeTransform=function() return {} end}
            gs={}
            function gs:BeginDeferredActorSpawnFromClass(controller,cls,transform,policy)
                assert(controller==pc and cls.path:match('BP_WeatherVolumeActor_C$') and policy==1)
                local o=obj('/World.Volume_'..(#actors+1));actors[#actors+1]=o
                return o
            end
            function gs:FinishSpawningActor(o)
                assert(o.VoyageWeatherPreset:IsA('/Script/Voyage.VoyageWeatherPreset'))
                if failFinish then error('construction failed') end
                o.VoyageWeatherVolume=obj(o.path..'.Component')
                o.VoyageWeatherVolume.GetOwner=function() return o end
                return o
            end
            function LoadAsset(path)
                if failLoad then return end
                local o=obj(path)
                function o:IsA(c) return c=='/Script/Voyage.VoyageWeatherPreset' end
            end
            package.loaded.core={isValid=function(o) return o~=nil and o:IsValid() end,
                address=function(o) return tostring(o) end,fullName=function(o) return 'Object '..o.path end,
                find=function(path) local o=registry[path];if o and o:IsValid() then return o end end,
                loadClass=obj,lib=function(s) return s=='math' and mathlib or gs end,log=function()end,
                pawn=function() return pawn end,pc=function() return pc end,rot=function()end,vec=function()end}
            weather=require('features.weather')
        """)

    def test_all_seven_and_resume(self):
        self.lua.execute("""
            for i,s in ipairs({'Default','Sunny','cloudy','Fog','Rain','Storm','LightSnow'}) do
                assert(weather.apply(i))
                local actor=actors[i]
                assert(actor.VoyageWeatherVolume.WeatherPreset.path:match('DA_WeatherPreset_'..s..'$'))
                assert(actor.VoyageWeatherVolume.Priority==100 and actor.VoyageWeatherVolume.Multiplier==1)
                if i>1 then assert(actors[i-1].gone) end
            end
            assert(weather.apply(0) and actors[7].gone)
            assert(weather.apply(0) and #actors==7)
        """)

    def test_failed_switch_and_permission(self):
        self.lua.execute("""
            assert(weather.apply(2))
            failLoad=true;assert(not weather.apply(3) and #actors==1)
            failLoad=false;failFinish=true
            assert(not weather.apply(4) and actors[2].gone and not actors[1].gone)
            host=false;assert(not weather.apply(0) and not actors[1].gone)
            host=true;assert(weather.apply(0) and actors[1].gone)
        """)

    def test_reused_path_and_world_travel(self):
        self.lua.execute("""
            assert(weather.apply(6))
            local foreign=obj(actors[1].path)
            assert(weather.apply(0) and not foreign.gone)
            assert(weather.apply(4))
            world='two';weather.onWorldChanged()
            assert(weather.apply(0) and not actors[2].gone)
        """)


@unittest.skipUnless(os.environ.get("WARDEN_JMAP"), "Optional game reflection dump")
class GameABI(unittest.TestCase):
    def test_weather_assets_and_callable_parameters(self):
        with gzip.open(os.environ["WARDEN_JMAP"], "rt", encoding="utf8") as f:
            objects = json.load(f)["objects"]
        widget = objects["/Game/UI/Game/HUD/BP_VoyageCheatWiget.Default__BP_VoyageCheatWiget_C"]
        paths = widget["property_values"]["VoyageWeatherPresets"]
        self.assertEqual(set(paths), {
            f"/Game/Data/Weather/WeatherPresets/DA_WeatherPreset_{s}.DA_WeatherPreset_{s}"
            for s in ("Default", "Sunny", "cloudy", "Fog", "Rain", "Storm", "LightSnow")
        })
        for name in ("Voyage.VoyageDurabilityIndicatorComponent:UpdateDurability",
                     "Engine.Actor:GetComponentByClass", "Engine.GameplayStatics:BeginDeferredActorSpawnFromClass",
                     "Engine.GameplayStatics:FinishSpawningActor", "Engine.KismetMathLibrary:MakeTransform",
                     "Engine.Actor:K2_GetActorLocation", "Engine.Actor:K2_DestroyActor"):
            with self.subTest(method=name):
                self.assertLessEqual(objects["/Script/" + name]["properties_size"], 512)

