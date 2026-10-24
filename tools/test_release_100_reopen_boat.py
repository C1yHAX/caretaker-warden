"""Real Lua userdata wrappers model UE4SS return-array entries; no game is started.

UI lifecycle checks are structural/input regressions, not a Slate renderer or FPS test.
"""
from pathlib import Path
import unittest
from lupa.lua54 import LuaRuntime
from test_admin_140 import BOAT
from test_boat import HARNESS as BOAT_CONTROLS

ROOT = Path(__file__).resolve().parent.parent


class Param:
    """Python objects appear as userdata in Lua, like UE4SS RemoteUnrealParam."""
    def __init__(self, value):
        self.value = value

    def get(self):
        return self.value

    def __getitem__(self, name):
        return getattr(self, name)


class Release100(unittest.TestCase):
    def runtime(self, harness=""):
        lua = LuaRuntime(unpack_returned_tuples=True)
        lua.execute(f'package.path="{(ROOT / "Warden/Scripts").as_posix()}/?.lua;'
                    f'{(ROOT / "tools/mock").as_posix()}/?.lua;"..package.path')
        lua.globals().wrap = Param
        if harness:
            lua.execute(harness)
        return lua

    def outfit(self):
        lua = self.runtime(BOAT)
        # Exercise the production unwrapping, not the identity stub used by old tests.
        lua.execute('''
            savedCore=core; package.loaded.core=nil
            package.preload.UEHelpers=function() return {} end
            actualCore=require('core')
            savedCore.unwrap=actualCore.unwrap
            savedCore.outList=actualCore.outList
            savedCore.str=actualCore.str
            package.loaded.core=savedCore
        ''')
        return lua

    def test_wrapped_component_return_and_actor_out_arrays_find_sockets(self):
        lua = self.outfit()
        lua.execute('''
            function boat:GetAttachedActors(out) out[1]=wrap(engine) end
            function engine:K2_GetComponentsByClass() return {wrap(comp)} end
            assert(type(wrap(comp))=='userdata')
            assert(O.start(boat,1,report)); O.tick()
            assert(H.spawns==1 and #H.deletes==0)
            socket.linked=cyl(); O.tick(); O.tick()
            assert(H.reports[1].ok and H.reports[1].text:find('1 verbunden',1,true))
        ''')

    def test_read_only_diagnosis_counts_occupied_and_foreign_links(self):
        lua = self.outfit()
        lua.execute('''
            old=cyl(); socket.linked=old
            function engine:K2_GetComponentsByClass() return {wrap(comp)} end
            ok,msg=O.inspect(boat)
            assert(ok and msg:find('1 Motoren',1,true) and msg:find('1 belegt',1,true))
            assert(H.spawns==0 and #H.deletes==0 and not old.dead)
            socket.linked=boat; ok,msg=O.inspect(boat)
            assert(ok and msg:find('1 fremde Verbindungen',1,true))
            assert(H.spawns==0 and #H.deletes==0 and not boat.dead)
        ''')

    def test_diagnosis_is_explicit_and_idle_does_not_rescan(self):
        lua = self.outfit()
        lua.execute('''
            H.scans=0
            function boat:GetAttachedActors(out) H.scans=H.scans+1;out[1]=wrap(engine) end
            O.inspect(boat); assert(H.scans==1)
            for i=1,100 do O.tick() end
            assert(H.scans==1)
            O.onWorldChanged(); assert(O.status()=='Noch nicht geprueft')
        ''')

    def test_foreign_connection_only_is_not_reported_as_success(self):
        lua = self.outfit()
        lua.execute('''
            socket.linked=boat; assert(O.start(boat,1,report)); O.tick(); O.tick()
            assert(not H.reports[1].ok and H.spawns==0 and #H.deletes==0)
        ''')

    def test_unwrapped_boat_attachments_allow_speed_and_restore(self):
        lua = self.runtime(BOAT_CONTROLS)
        lua.execute('''
            a=makeBoat('A');r=makeRotor(a,'Rotor',10)
            rawset(a,'GetAttachedActors',function(self,out) out[1]=wrap(r) end)
            assert(selectBoat());speed(6)
            assert(r.RotationSpeedToLinearSpeed==20)
            H.toggle(false);assert(r.RotationSpeedToLinearSpeed==10)
        ''')

    def test_unwrapped_boat_components_and_modules_are_repaired(self):
        lua = self.runtime(BOAT_CONTROLS)
        lua.execute('''
            a=makeBoat('A');actor=attach(a,object('Part','Part'))
            module=makeModule(actor,30,nil,a)
            rawset(a,'GetAttachedActors',function(self,out) out[1]=wrap(actor) end)
            rawset(a,'GetAllModules',function(self,out) out[1]=wrap(module) end)
            rawset(actor,'K2_GetComponentsByClass',function(self,cls)
                if cls.p.path==MODULE then return {wrap(module)} else return {} end
            end)
            assert(selectBoat());repair();drain()
            assert(module:GetDurability()==100 and H.repairs==1)
        ''')

    def test_every_page_reopens_without_retained_paint_cache_and_still_clicks(self):
        lua = self.runtime('''
            mock=require('ue4ss_mock');require('main');ui=require('ui')
            mock.keybinds[1].fn();mock.timers[50]()
        ''')
        lua.execute('''
            for i=1,#ui.pages do
                ui.selectPage(i)
                assert(ui.pages[i].root.__name=='/Script/UMG.ScrollBox')
            end
            for _,w in ipairs(mock.spawned) do
                assert(w.__name~='/Script/UMG.InvalidationBox')
            end
            clicked=0
            button=ui.button(ui.pages[1].left,'Lifecycle check','action',function() clicked=clicked+1 end)
            local hook
            for path,fn in pairs(mock.hooks) do
                if path:find('OnButtonClickedEvent',1,true) then hook=fn end
            end
            assert(hook)
            local count=#mock.created
            for cycle=1,20 do
                ui.hide();ui.show()
                for i=1,#ui.pages do ui.selectPage(i);ui.tick() end
                ui.selectPage(1)
                hook(mock.new('Ctx',{get=function() return button end}))
            end
            assert(clicked==20 and #mock.created==count)
        ''')


if __name__ == '__main__':
    unittest.main()
