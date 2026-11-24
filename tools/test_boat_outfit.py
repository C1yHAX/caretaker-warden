"""Original developer-menu item-spawn contract, with no running game or physics.

Exercise the real outfitter through native-shaped soft/return userdata, not a
stubbed crafter. The separate reflection fixture checks UE4SS parameter bounds.
"""
import json
from pathlib import Path
import unittest
from lupa.lua54 import LuaRuntime
from test_admin_140 import BOAT, Param

ROOT = Path(__file__).resolve().parent.parent


class BoatOutfit(unittest.TestCase):
    def runtime(self):
        lua = LuaRuntime(unpack_returned_tuples=True)
        lua.execute(f'package.path="{(ROOT / "Warden/Scripts").as_posix()}/?.lua;"..package.path')
        lua.execute('require("i18n").setLanguage("de")')
        lua.globals().wrap = Param
        lua.execute(BOAT)
        return lua

    def test_all_original_engine_levels_use_real_item_assets_and_item_initialization(self):
        for kind in ('Diesel', 'Electric'):
            for level, suffix in enumerate(('', '_Booster', '_SuperBooster', '_CheatBooster'), 1):
                with self.subTest(kind=kind, level=level):
                    lua = self.runtime()
                    lua.execute(f'''
                        comp.SocketTypeOverride='{kind}Engine'
                        assert(O.start(boat,{level},report));O.tick()
                        local name='DA_Item_{kind}EngineCylinder{suffix}'
                        assert(H.item.asset=='/Game/Data/Assets/Items/'..name..'.'..name)
                        assert(H.spawns==1 and H.deletedBeforeSpawn==0)
                        assert(H.data.ItemCount==1 and H.data.Flags==0 and H.data.Version==30)
                        assert(type(H.data.Timestamp)=='number')
                        assert(H.settings.bForceAutoCollect==false and H.settings.AutoCollectRadius==500)
                        assert(H.settings.bResolveOverlaps and H.settings.bAwake and H.settings.bSimulatePhysics)
                        assert(H.settings.LinearVelocity.X==0 and H.settings.AngularVelocity.Z==0)
                        assert(H.transform.Rotation.Yaw==({1 if kind=='Electric' else 0}*180))
                        socket.linked=H.created;O.tick();O.tick();assert(H.reports[1].ok)
                    ''')

    def test_rotated_scaled_socket_and_moving_boat_match_original_geometry(self):
        lua = self.runtime()
        lua.execute('''
            comp.SocketTypeOverride='ElectricEngine'
            comp.RelativeScale3D={X=2,Y=3,Z=4}
            function comp:K2_GetComponentRotation() return {Pitch=0,Yaw=90,Roll=0} end
            assert(O.start(boat,4,report));O.tick()
            local p=H.transform.Translation
            assert(math.abs(p.X-95)<0.00001 and math.abs(p.Y-204)<0.00001 and p.Z==365)
        ''')

    def test_bad_soft_reference_preserves_old_cylinder(self):
        lua = self.runtime()
        lua.execute('''
            old=cyl();socket.linked=old
            function sys:LoadAsset_Blocking() return object({}) end
            assert(O.start(boat,1,report));O.tick()
            assert(not old.dead and H.spawns==0 and #H.deletes==0 and not H.reports[1].ok)
        ''')

    def test_bad_geometry_and_missing_world_preserve_old_cylinder(self):
        for fault in ("function engine:GetVelocity() return {X=0/0,Y=0,Z=0} end",
                      "function misc:GetActorWorld() return nil end",
                      "function gameplay:GetRealTimeSeconds() return nil end"):
            lua = self.runtime()
            lua.execute(fault)
            lua.execute('''
                old=cyl();socket.linked=old;assert(O.start(boat,1,report));O.tick()
                assert(not old.dead and H.spawns==0 and #H.deletes==0 and not H.reports[1].ok)
            ''')

    def test_failed_removal_does_not_spawn_over_existing_cylinder(self):
        lua = self.runtime()
        lua.execute('''
            old=cyl();socket.linked=old
            function persist:DestroyActor() end
            assert(O.start(boat,1,report));O.tick()
            assert(not old.dead and H.spawns==0 and not H.reports[1].ok)
        ''')

    def test_empty_native_spawn_result_stops_batch_and_never_reports_success(self):
        lua = self.runtime()
        lua.execute('''
            H.spawnReject=true;assert(O.start(boat,1,report));O.tick()
            for i=1,20 do O.tick() end
            assert(H.spawns==1 and not H.reports[1].ok)
            assert(H.reports[1].text:find('1 unbestaetigt',1,true))
        ''')

    def test_only_the_returned_actor_on_the_target_socket_confirms_success(self):
        lua = self.runtime()
        lua.execute('''
            assert(O.start(boat,1,report));O.tick();socket.linked=cyl();O.tick()
            assert(#H.reports==0)
            now=9;O.tick();assert(not H.reports[1].ok)
        ''')

    def test_timeout_uses_elapsed_game_real_time_not_lua_cpu_time(self):
        lua = self.runtime()
        lua.execute('''
            os.clock=function() return 0 end
            assert(O.start(boat,1,report));O.tick()
            now=9;O.tick();assert(not H.reports[1].ok)
        ''')

    def test_preflight_rejects_invalid_levels_and_client(self):
        lua = self.runtime()
        lua.execute('''
            for _,level in ipairs({0,5,1.5,math.huge,0/0,'1'}) do assert(not O.start(boat,level,report)) end
            boat.authority=false;assert(not O.start(boat,1,report))
            assert(H.spawns==0 and #H.deletes==0)
        ''')

    def test_reflected_function_blocks_fit_ue4ss_and_soft_reference_is_native(self):
        fixture = json.loads((ROOT / 'verification/boat-outfit-abi.json').read_text(encoding='utf-8'))
        functions = fixture['functions']
        self.assertEqual(functions['/Script/Voyage.VoyageMiscBlueprintFunctionLibrary:SpawnActorForItem']['properties_size'], 360)
        for path, function in functions.items():
            with self.subTest(function=path):
                self.assertLessEqual(function['properties_size'], 512)
                for prop in function['properties']:
                    self.assertLessEqual(prop['offset'] + prop['size'] * prop['array_dim'], 512)
        spawn = functions['/Script/Voyage.VoyageMiscBlueprintFunctionLibrary:SpawnActorForItem']
        self.assertEqual([p['name'] for p in spawn['properties']],
                         ['World','ItemClass','Transform','InData','Settings','ReturnValue'])
        self.assertEqual(spawn['properties'][1]['type'], 'SoftObjectProperty')
        self.assertEqual(spawn['properties'][1]['size'], 40)


if __name__ == '__main__':
    unittest.main()
