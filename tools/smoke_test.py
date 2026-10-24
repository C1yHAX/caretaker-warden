"""Builds the whole Warden window against a UE4SS stand-in and clicks every button.

Catches what a syntax check cannot: nil globals, typos in field names, wrong arity in
our own helpers, errors in page builders and click handlers. It says nothing about
whether the game accepts the calls - that needs the game.

Requires lupa (pip install lupa).   Usage:  python tools/smoke_test.py
"""
import pathlib
import shutil
import sys
import tempfile

import lupa.lua54 as lua54

ROOT = pathlib.Path(__file__).resolve().parent.parent
MOCK = ROOT / "tools" / "mock"

# The mod writes settings and saved positions next to itself, so the test runs on a
# throwaway copy instead of the source tree.
WORK = pathlib.Path(tempfile.mkdtemp(prefix="warden-smoke-"))
shutil.copytree(ROOT / "Warden", WORK / "Warden")
SCRIPTS = WORK / "Warden" / "Scripts"

DRIVER = """
function(mock)
  local out = {}
  local function log(s) out[#out + 1] = s end
  local open = mock.keybinds[1]
  assert(open ~= nil, "no keybind registered")
  open.fn()
  mock.timers[50]()
  local ui = require("ui")
  assert(ui.isOpen and #ui.pages == 9, "F1 did not build and open all page slots")
  log("pages built: " .. #ui.pages .. ", open: " .. tostring(ui.isOpen))
  for i = 1, #ui.pages do ui.selectPage(i) ui.tick() end
  local hookFn
  for path, fn in pairs(mock.hooks) do
    if path:find("OnButtonClickedEvent", 1, true) then hookFn = fn end
  end
  assert(hookFn, "menu click hook missing")
  local created = {}
  for i, w in ipairs(mock.created) do created[i] = w end
  for _, w in ipairs(created) do
    hookFn(mock.new("Ctx", { get = function() return w end }))
  end
  log("clicked " .. #created .. " buttons")
  for _ = 1, 3 do for _, fn in ipairs(mock.loops) do fn() end end
  for _, fn in ipairs(mock.delayed) do fn() end
  assert(mock.keybinds[2], "panic binding missing")
  mock.keybinds[2].fn()
  mock.timers[50]()
  assert(not ui.isOpen, "panic did not close the menu")
  open.fn()
  mock.timers[50]()
  assert(ui.isOpen, "menu did not reopen after panic")
  open.fn()
  mock.timers[50]()
  assert(not ui.isOpen, "F1 did not close the menu")
  assert(#mock.forbidden == 0, table.concat(mock.forbidden, "; "))
  log("final open state: " .. tostring(ui.isOpen))
  return out
end
"""


def main() -> int:
    sys.stdout.reconfigure(encoding="utf-8")
    lua = lua54.LuaRuntime(unpack_returned_tuples=True)
    lua.execute(f'package.path = "{SCRIPTS.as_posix()}/?.lua;{MOCK.as_posix()}/?.lua;" .. package.path')
    lua.execute("MOCK = require(\"ue4ss_mock\")")
    mock = lua.globals().MOCK
    lua.execute('require("main")')
    steps = lua.eval(DRIVER)(mock)
    for s in steps.values():
        print(s)
    log = list(mock.log.values())
    errors = [line for line in log if "ERROR" in line or "failed" in line]
    print(f"log lines: {len(log)}, error lines: {len(errors)}")
    seen = set()
    if "--verbose" in sys.argv:
        for line in log:
            print("  LOG", line)
    for e in errors:
        if e not in seen:
            seen.add(e)
            print("  ", e)
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
