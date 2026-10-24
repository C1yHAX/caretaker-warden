"""Regressions for next-ID/head mismatch, safe retrofit, UI writes and bounded logs.

No game launch. Strict doubles exercise guards; they do not emulate engine physics.
"""
from pathlib import Path
import unittest
from lupa.lua54 import LuaRuntime
from test_storage_instant import HARNESS as INSTANT

ROOT=Path(__file__).resolve().parent.parent

BOAT=r'''
H={n=0,objects={},spawns=0,deletes={},logs={},reports={}}
now=0;os.clock=function() return now end
function object(t)
 H.n=H.n+1;t.id=H.n;t.path='/Game/Test.'..t.id;H.objects[t.path]=t
 function t:IsValid() return not self.dead end
 function t:GetOwner() return self.owner end
 function t:IsA(c) return self.kind==c end
 function t:HasAuthority() return self.authority~=false end
 function t:IsActorBeingDestroyed() return self.dead==true end
 function t:GetAttachParentActor() return self.parent end
 function t:K2_DestroyActor() self.dead=true end
 return t
end
boat=object({kind='boat'});engine=object({kind='/Script/Voyage.VoyageModuleEngineActor',parent=boat})
comp=object({SocketTypeOverride='DieselEngine',owner=engine});socket=object({Owner=comp,RelativeLocation={X=1,Y=2,Z=3}})
comp.Sockets={socket}
function comp:IsPlugSocket() return false end
function comp:K2_GetComponentToWorld() return {} end
function socket:IsPlugged() return self.linked~=nil and not self.linked.dead end
socket.AttachedToSocket={Get=function() if socket.linked and not socket.linked.dead then return object({Owner=object({owner=socket.linked})}) end end}
function boat:GetAttachedActors() return {engine} end
function engine:K2_GetComponentsByClass() return {comp} end
function cyl() return object({kind='/Game/Blueprints/Modules/Utility/Boat/BP_Module_Diesel_Engine_Cylinder.BP_Module_Diesel_Engine_Cylinder_C'}) end
pawn=object({});pc=object({})
local mathlib=object({})
function mathlib:TransformLocation(t,loc) return loc end
function mathlib:MakeTransform(pos,rot,scale) return {Translation=pos} end
persist=object({})
function persist:DestroyActor(o,delay) assert(o~=boat and o~=engine);H.deletes[#H.deletes+1]=o;o.dead=true end
sub=object({});function sub:GetWorldSubsystem() return persist end
core={isValid=function(o) return type(o)=='table' and o.IsValid and o:IsValid() end,
 address=function(o) return o and o.id end,fullName=function(o) return o and o.path and ('Object '..o.path) or '?' end,
 find=function(p) return H.objects[p] or p end,loadClass=function(p) return p end,
 pc=function() return pc end,pawn=function() return pawn end,
 outList=function(_,fn) return fn({}) end,unwrap=function(x) return x end,str=tostring,
 vec=function(x,y,z) return {X=x,Y=y,Z=z} end,rot=function(p,y,r) return {pitch=p,Yaw=y,Roll=r} end,
 xyz=function(p) if p then return p.X,p.Y,p.Z end end,
 lib=function(n) if n=='math' then return mathlib elseif n=='subsystem' then return sub end end,
 log=function(s) H.logs[#H.logs+1]=s end}
package.loaded.core=core
package.loaded['features.spawn']={craft=function(mod,t,parent)
 assert(parent==engine and mod.value==37)
 if H.reject then return false,'rejected' end
 H.spawns=H.spawns+1;H.crafter=object({});return true,'started',H.crafter
end}
function report(s,ok) H.reports[#H.reports+1]={text=s,ok=ok} end
O=require('features.boat_outfit')
'''

class Admin140(unittest.TestCase):
 def runtime(self,script=''):
  lua=LuaRuntime(unpack_returned_tuples=True)
  lua.execute(f'package.path="{(ROOT/"Warden/Scripts").as_posix()}/?.lua;{(ROOT/"tools/mock").as_posix()}/?.lua;"..package.path')
  if script:lua.execute(script)
  return lua

 def test_instant_uses_queue_head_not_next_id(self):
  lua=self.runtime(INSTANT)
  lua.execute('''
  f=craft(0);f.CurrentFabricationId=18;f.ItemQueue[1].FabricationId=17
  function f:GetQueueIndexByFabricationId() error('next ID is not the active job') end
  I.setEnabled(true);I.tick();assert(f.ProgressTimerMax==0.05)
  ''')

 def test_instant_build_is_separate_and_only_own_unblocked(self):
  lua=self.runtime(INSTANT)
  lua.execute('''
  own,o=craft(20,true);function o:GetOwner() return pawn end;o.IsBlocked=false
  blocked,b=craft(20,true);function b:GetOwner() return pawn end;b.IsBlocked=true
  other,q=craft(20,true);function q:GetOwner() return obj({}) end;q.IsBlocked=false
  regular=craft(20)
  I.setBuildEnabled(true);I.tick()
  assert(own.ProgressTimerMax==0.05)
  assert(blocked.ProgressTimerMax==10 and other.ProgressTimerMax==10 and regular.ProgressTimerMax==10)
  ''')

 def test_instant_delivers_already_finished_output_without_duplication(self):
  lua=self.runtime(INSTANT)
  lua.execute('''
  f=craft(0);f.active=false;f.OutputQueue={{paid=true}};f.OutputTimer=3
  I.setEnabled(true);I.tick()
  assert(f.OutputTimer==0.001 and #f.OutputQueue==1 and f.OutputQueue[1].paid)
  assert(f.ProgressTimerMax==10)
  ''')

 def test_empty_queue_is_never_indexed_or_expanded(self):
  lua=self.runtime(INSTANT)
  lua.execute('''
  f=craft(0);f.ItemQueue=setmetatable({},{__index=function() error('out of bounds read expands UE4SS array') end})
  I.setEnabled(true);I.tick();assert(f.ProgressTimerMax==10)
  ''')

 def test_instant_scan_throttled_and_disabled_is_idle(self):
  lua=self.runtime(INSTANT)
  lua.execute('''
  now=0;os.clock=function() return now end;f=craft(0)
  I.setEnabled(true);for i=1,20 do I.tick() end;assert(H.scans==1)
  now=1;I.tick();assert(H.scans==2)
  I.setEnabled(false);now=100;I.tick();assert(H.scans==2)
  ''')

 def test_boat_hull_engine_and_unknown_objects_never_replaced(self):
  for kind in ('boat','engine','object({kind="unknown"})'):
   lua=self.runtime(BOAT)
   lua.execute(f'socket.linked={kind};assert(O.start(boat,1,report));O.tick();O.tick();assert(#H.deletes==0 and H.spawns==0)')

 def test_boat_cylinder_only_removed_after_crafter_is_ready(self):
  lua=self.runtime(BOAT)
  lua.execute('''
  old=cyl();socket.linked=old;assert(O.start(boat,1,report));O.tick()
  assert(H.spawns==1 and #H.deletes==1 and H.deletes[1]==old and not boat.dead and not engine.dead)
  socket.linked=cyl();O.tick();O.tick()
  assert(H.reports[1].ok and H.reports[1].text:find('1 verbunden',1,true))
  ''')

 def test_boat_prepare_failure_preserves_existing_cylinder(self):
  lua=self.runtime(BOAT)
  lua.execute('''
  old=cyl();socket.linked=old;H.reject=true;assert(O.start(boat,1,report));O.tick();O.tick()
  assert(not old.dead and #H.deletes==0 and not H.reports[1].ok)
  ''')

 def test_boat_unconfirmed_snap_reports_failure_not_success(self):
  lua=self.runtime(BOAT)
  lua.execute('''
  assert(O.start(boat,1,report));O.tick();assert(H.spawns==1)
  now=9;O.tick();O.tick();assert(not H.reports[1].ok and H.reports[1].text:find('1 unbestaetigt',1,true))
  ''')

 def test_boat_failed_snap_stops_before_replacing_more_cylinders(self):
  lua=self.runtime(BOAT)
  lua.execute('''second=object({Owner=comp,RelativeLocation={X=2,Y=3,Z=4}})
  function second:IsPlugged() return false end
  comp.Sockets={socket,second};assert(O.start(boat,1,report));O.tick()
  now=9;O.tick();for i=1,20 do O.tick() end;assert(H.spawns==1 and not H.reports[1].ok)
  ''')

 def test_boat_duplicate_world_change_and_detachment(self):
  lua=self.runtime(BOAT)
  lua.execute('''
  assert(O.start(boat,1,report));assert(not O.start(boat,1,report))
  engine.parent=nil;O.tick();O.tick();assert(H.spawns==0 and #H.deletes==0)
  engine.parent=boat;assert(O.start(boat,1,report));O.onWorldChanged();O.tick();assert(H.spawns==0)
  ''')

 def test_log_bounded_ordered_truncated_and_clear(self):
  lua=self.runtime()
  lua.execute('''
  j=require('journal');for i=1,10000 do j.add(tostring(i)) end
  a=j.lines(1000);assert(#a==200 and a[1]:find('10000',1,true) and a[200]:find('9801',1,true))
  j.add(string.rep('x',10000));assert(#j.lines(1)[1]<650)
  j.clear();assert(#j.lines(200)==0)
  ''')

 def test_unchanged_text_visibility_and_style_have_no_engine_writes(self):
  lua=self.runtime('mock=require("ue4ss_mock");ui=require("ui");core=require("core");require("main");mock.keybinds[1].fn();mock.timers[50]()')
  lua.execute('''
  t=ui.text('x');ui.setText(t,'stable');ui.setVisible(t,true)
  w=mock.created[2];ui.style(w,'chipOn')
  n=#mock.calls;styles=mock.styleWrites
  for i=1,100 do ui.setText(t,'stable');ui.setVisible(t,true);ui.style(w,'chipOn') end
  assert(mock.styleWrites==styles)
  for i=n+1,#mock.calls do assert(not mock.calls[i]:find(':Set',1,true) and not mock.calls[i]:find(':Conv_',1,true)) end
  for _,s in ipairs(mock.log) do assert(not s:find('[step]',1,true)) end
  ''')

 def test_hidden_log_does_not_build_or_refresh_and_reopen_reuses_widgets(self):
  lua=self.runtime('mock=require("ue4ss_mock");require("main");ui=require("ui");mock.keybinds[1].fn();mock.timers[50]()')
  lua.execute('''
  assert(#ui.pages==9 and not ui.pages[9].built)
  count=#mock.created
  for i=1,20 do ui.hide();ui.show();ui.tick() end
  assert(#mock.created==count and not ui.pages[9].built)
  ''')

if __name__=='__main__':unittest.main()
