#!/usr/bin/env python3
"""Run a Lua script against the addon sources.

Usage:  python tools/run_lua.py [--engine auto|path|obs|resolve] <script.lua> [args...]

Engines
  path     lua / luajit / luau found on PATH (preferred, run as a subprocess)
  obs      OBS Studio's lua51.dll (LuaJIT build) loaded read-only through ctypes
  resolve  DaVinci Resolve's lua5.1.dll (PUC Lua 5.1) loaded read-only through ctypes
  auto     path if available, otherwise obs, otherwise resolve

Nothing is downloaded or installed. The DLLs are only loaded, never modified.
package.path is set to <root>/src, <root>/tests and <root>. The exit code is the number the
script returns (0 = success).
"""
import ctypes
import os
import shutil
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DLLS = {
    "obs": r"C:\Program Files\obs-studio\bin\64bit\lua51.dll",
    "resolve": r"C:\Program Files\Blackmagic Design\DaVinci Resolve\lua5.1.dll",
}
LUA_GLOBALSINDEX = -10002  # Lua 5.1 / LuaJIT


def lua_str(s):
    return '"' + s.replace("\\", "/").replace('"', '\\"') + '"'


def prelude(script, args):
    root = ROOT.replace("\\", "/")
    argt = ", ".join(lua_str(a) for a in args)
    return f"""
io.stdout:setvbuf("no")
ROOT = {lua_str(root)}
package.path = ROOT.."/src/?.lua;"..ROOT.."/tests/?.lua;"..ROOT.."/?.lua;"..package.path
arg = {{ [0] = {lua_str(script)}{', ' + argt if argt else ''} }}
local f, err = loadfile({lua_str(script)})
if not f then io.stderr:write(tostring(err).."\\n"); __RC = 2; return end
local ok, res = xpcall(function() return f(unpack(arg)) end, debug.traceback)
io.stdout:flush()
if not ok then io.stderr:write(tostring(res).."\\n"); __RC = 1
else __RC = tonumber(res) or 0 end
io.stderr:flush()
"""


def run_dll(dll_path, script, args):
    L = ctypes.CDLL(dll_path)
    L.luaL_newstate.restype = ctypes.c_void_p
    L.luaL_openlibs.argtypes = [ctypes.c_void_p]
    L.luaL_loadstring.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
    L.lua_pcall.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_int, ctypes.c_int]
    L.lua_tolstring.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_void_p]
    L.lua_tolstring.restype = ctypes.c_char_p
    L.lua_getfield.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_char_p]
    L.lua_tonumber.argtypes = [ctypes.c_void_p, ctypes.c_int]
    L.lua_tonumber.restype = ctypes.c_double
    st = L.luaL_newstate()
    L.luaL_openlibs(st)
    rc = L.luaL_loadstring(st, prelude(script, args).encode("utf-8"))
    if rc != 0:
        print("prelude load error:", L.lua_tolstring(st, -1, None), file=sys.stderr)
        return 2
    rc = L.lua_pcall(st, 0, 0, 0)
    if rc != 0:
        print("prelude run error:", L.lua_tolstring(st, -1, None), file=sys.stderr)
        return 3
    L.lua_getfield(st, LUA_GLOBALSINDEX, b"__RC")
    return int(L.lua_tonumber(st, -1))


def run_path(exe, script, args):
    # Standalone interpreter: same prelude via -e would be awkward, so use a tiny driver file.
    driver = os.path.join(os.path.dirname(os.path.abspath(__file__)), "_driver.lua")
    with open(driver, "w", encoding="utf-8") as fh:
        fh.write(prelude(script, args) + "\nos.exit(__RC)\n")
    try:
        return subprocess.call([exe, driver])
    finally:
        os.remove(driver)


def main(argv):
    engine = "auto"
    if len(argv) >= 2 and argv[0] == "--engine":
        engine, argv = argv[1], argv[2:]
    if not argv:
        print(__doc__)
        return 2
    script = os.path.abspath(argv[0])
    args = argv[1:]
    if engine in ("auto", "path"):
        for name in ("luajit", "lua", "lua5.1", "luau"):
            exe = shutil.which(name)
            if exe:
                return run_path(exe, script, args)
        if engine == "path":
            print("no lua interpreter on PATH", file=sys.stderr)
            return 2
        engine = "obs"
    if engine not in DLLS:
        print("unknown engine", engine, file=sys.stderr)
        return 2
    order = [engine] + [e for e in ("obs", "resolve") if e != engine]
    for e in order:
        if os.path.exists(DLLS[e]):
            return run_dll(DLLS[e], script, args)
    print("no Lua runtime found (install lua/luajit or adjust DLLS in tools/run_lua.py)", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
