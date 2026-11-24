"""Regressions for the 1.0.2 'get' crash and spatial repair workloads."""
import json
import unittest
from pathlib import Path
from lupa.lua54 import LuaRuntime
import test_inventory_repair as fixtures
from test_release_100_reopen_boat import Param

ROOT=Path(__file__).resolve().parent.parent

class BareObject:
    """A real Lua userdata whose reflected get lookup is unsafe, like the dump."""
    def __init__(self): self.lookups=[]
    def type(self): return "UObject"
    def __getitem__(self,key):
        if key=="type": return self.type
        self.lookups.append(key)
        raise RuntimeError('Native reflected lookup on expired UObject: '+key)

class EphemeralParam(Param):
    def __init__(self,value): super().__init__(value);self.expired=False;self.reads=0
    def get(self):
        self.reads+=1
        if self.expired: raise RuntimeError('Out-param storage expired at tick boundary')
        return self.value

class Unwrap(unittest.TestCase):
    def setUp(self):
        self.lua=LuaRuntime(unpack_returned_tuples=True)
        self.lua.execute(f'package.path={json.dumps((ROOT/"Warden/Scripts/?.lua").as_posix()+";")}..package.path;package.preload.UEHelpers=function()return {{}}end')
        self.lua.execute('core=require("core")')

    def test_bare_expired_userdata_never_probes_get(self):
        o=BareObject();self.lua.globals().obj=o
        self.lua.execute('assert(type(obj)=="userdata" and core.unwrap(obj)==obj)')
        self.assertEqual(o.lookups,[])

    def test_actual_param_types_are_unwrapped(self):
        for kind in ['RemoteUnrealParam','LocalUnrealParam']:
            p=Param(42);p.type=lambda *_:kind;self.lua.globals().obj=p
            self.lua.execute('assert(core.unwrap(obj)==42)')

    def test_unknown_userdata_never_probes_get(self):
        o=BareObject();o.type=lambda *_:'FSoftObjectPtr';self.lua.globals().obj=o
        self.lua.execute('assert(core.unwrap(obj)==obj)');self.assertEqual(o.lookups,[])

class AreaLifetime(unittest.TestCase):
    def setUp(self):
        fixture=fixtures.Repairs();fixture.setUp();self.lua=fixture.lua
        self.lua.execute('''
            function poison(o)
                resolved[o.p.lookup]=nil
                local mt=getmetatable(o);local old=mt.__index
                mt.__index=function(self,k) stale=stale+1;error('freed UObject touched: '..k) end
            end
            stale=0
            function assertPlainJob()
                local function plain(v)
                    assert(type(v)~='userdata' and type(v)~='function')
                    if type(v)=='table' then assert(getmetatable(v)==nil);for k,x in pairs(v) do plain(k);plain(x) end end
                end
                for i=1,30 do
                    local key,value=debug.getupvalue(area.tick,i)
                    if key=='job' and value then plain(value) end
                end
            end
        ''')

    def test_unload_actor_with_same_world_and_controller_never_touches_old_ref(self):
        self.lua.execute('''
            local actor,damage=target('Unload',0)
            assert(area.start());area.tick();assertPlainJob()
            poison(actor);poison(damage);candidates={}
            drainArea();assert(stale==0 and H.repairs==0)
        ''')

    def test_unload_component_after_discovery_and_address_reuse(self):
        self.lua.execute('''
            local actor,first=target('One',0,100)
            local second=track(makeDamage(actor,10));rawset(second,'bInitialized',true)
            -- Inspect the actor but stop before processing components.
            local clock=0;os.clock=function()clock=clock+0.004;return clock end
            assert(area.start());area.tick();area.tick();assertPlainJob()
            local path=second.p.lookup;poison(second)
            local replacement=makeDamage(actor,10);rawset(replacement,'bInitialized',true)
            resolved[path]=replacement -- same object path, different address
            drainArea();assert(stale==0 and H.repairs==0 and replacement.Health==10)
        ''')

    def test_out_parameter_wrappers_are_consumed_in_the_query_tick(self):
        wrappers=[]
        def wrap(value):
            p=EphemeralParam(value);wrappers.append(p);return p
        self.lua.globals().wrap=wrap
        self.lua.execute('''
            local actor,damage=target('Wrapped',0)
            local sys=StaticFindObject('/Script/Engine.Default__KismetSystemLibrary')
            local native=sys.BoxOverlapActors
            function sys:BoxOverlapActors(...)
                local args={...};local out=args[7];native(self,...)
                for i,o in ipairs(out) do out[i]=wrap(o) end
                return #out>0
            end
            assert(area.start());area.tick();assertPlainJob()
        ''')
        self.assertTrue(wrappers)
        for p in wrappers:p.expired=True;self.assertEqual(p.reads,1)
        self.lua.execute('drainArea();assert(H.repairs==1)')
        self.assertTrue(all(p.reads==1 for p in wrappers))

    def test_250_metre_job_is_spatial_bounded_and_never_writes_twice_per_tick(self):
        self.lua.execute('''
            H.areaStep.set(5);local expected=0
            for x=-24000,24000,4000 do for y=-24000,24000,4000 do
                local actor=target('Grid'..x..':'..y,x);actor.p.y=y
                if x*x+y*y<=25000^2 then expected=expected+1 end
            end end
            target('FarAway',10000000)
            assert(area.start())
            for tick=1,2000 do
                if not area.busy() then break end
                local q,r,d=finds,H.repairs,H.componentLists
                area.tick();assertPlainJob()
                assert(finds-q<=1 and H.repairs-r<=1 and H.componentLists-d<=1)
            end
            assert(not area.busy() and H.repairs==expected and finds>1 and finds<=100)
            for _,box in ipairs(H.boxes) do assert(box.extent.X<=2500 and box.extent.Y<=2500) end
        ''')

    def test_dense_cell_subdivision_and_query_failures_report_incomplete(self):
        self.lua.execute('''
            H.dense=true;assert(area.start());drainArea()
            assert(finds>1 and finds<=85 and H.repairs==0)
            assert(tonumber(area.status():match('(%d+) Fehler'))>0)
            H.dense=false;H.queryFail=true;assert(area.start());drainArea()
            assert(area.status():find('1 Fehler',1,true))
        ''')

    def test_cancel_after_query_releases_all_work_and_uninitialized_is_skipped(self):
        self.lua.execute('''
            local actor,damage=target('Uninitialized',0);rawset(damage,'bInitialized',false)
            assert(area.start());drainArea();assert(H.repairs==0)
            assert(area.status():find('1 uebersprungen',1,true))
            assert(area.start());area.tick();area.cancel();poison(actor);poison(damage)
            local q=finds;area.tick();assert(finds==q and stale==0)
        ''')

if __name__=='__main__':unittest.main(verbosity=2)
