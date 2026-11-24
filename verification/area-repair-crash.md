# Area repair crash — 1.0.3

2026-11-20. This is an offline investigation of the user's 1.0.2 crash and a
bounded implementation correction. The game was not launched.

## Observed crash

The last UE4SS log starts a 10 m area repair at 03:26:41 and has no completion
message. Streaming activity is logged during the operation. The Unreal crash
report was written at 03:27:26 and reports an access violation in UE4SS.

The exception context (not the later crash-handler thread context) in the
minidump identifies UE4SS+0x2237ad. Disassembly shows a dereference of a corrupted
class/field-list address, called through the reflected property lookup path at
UE4SS+0x2ab015. The lookup-name object addressed by R13 contains `get` in both
its narrow and wide string representations. The UObject storage referenced by
R12 no longer contains a valid class pointer. No native stack frame identifies
OverrideHealth as the faulting operation.

Warden 1.0.2's `core.unwrap` calls `v:get()` for every userdata before its callers
check UObject validity. On a bare UObject, `get` is a reflected-property lookup;
it is not the parameter-wrapper method. Thus the old code contains the exact
unsafe operation seen in the dump. The dump does not contain a full Lua traceback,
so it does not independently name the Lua caller. Retaining a global array of
streamable components across ticks supplies a concrete route to that operation.
There is no hang dump for the earlier 250 m attempt; its exact blocking call is
unconfirmed. The old scan was global regardless of the selected radius.

## Fix

- Inspect the wrapper's local `type()` method and call `get()` only for
  RemoteUnrealParam/LocalUnrealParam. Never probe it on bare UObjects. The pinned
  [UE4SS header](https://github.com/UE4SS-RE/RE-UE4SS/blob/527a483b/UE4SS/include/LuaType/LuaUObject.hpp)
  and [parameter implementation](https://github.com/UE4SS-RE/RE-UE4SS/blob/527a483b/UE4SS/src/LuaType/LuaUObject.cpp)
  distinguish these local wrapper methods from reflected member lookup.
- Replace FindAllOf with local BoxOverlapActors queries. One column of at most
  50×50 m is queried per tick; vertical extent follows the requested sphere.
  Exact spherical distance is checked again before repair. Dense cells split
  into four smaller columns, at most three times. An unresolved dense cell is
  counted as an error, not as repaired.
- Consume out-parameter wrappers in their originating callback. Store only
  scalar records across ticks. Resolve each actor/component by path again and
  compare the expected address, world, authority and ownership before use.
- Inspect at most one actor's component list per tick; at most eight work steps
  and one health mutation. A 3 ms between-step budget yields early, but cannot
  preempt a single native engine call. Idle ticks perform no spatial searches.
- Require initialized damage components. Report failures/skips and log health
  mutations. Cancel/world change drops all queued metadata. Default radius 10 m;
  the 250 m choice remains available.

BoxOverlapActors has a 120-byte reflected parameter block in the supplied game
dump, including its return value, below UE4SS's 512-byte buffer. ObjectTypes uses
the six standard object-query channels; custom collision channels and objects
without queryable collision are outside this area search. No global fallback
reintroduces the original lifetime or whole-world scan behavior.

## Verification boundaries

Regression tests use real Lua execution and userdata stand-ins. They check the
unsafe lookup, local/remote parameter handling, unloading with unchanged world
and player, changed addresses under the same path, immediate out-param
consumption, queue contents containing no UObject references, radius boundaries,
250 m coverage with repeated actors, dense-cell subdivision, budget limits,
initialization checks, query failures and cancellation.

The offline tests cannot reproduce native memory faults or measure game FPS.
Actual repair effects and stability in the user's loaded world require the next
in-game test; no crash-free guarantee is inferred from passing mocks.
