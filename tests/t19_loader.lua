local T = require("tf")
local H = require("harness")
local Mock = H.Mock

T.suite("19 Loader script")

local function read(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local s = f:read("*a")
  f:close()
  return s
end

local BUNDLE = ROOT .. "/dist/jhc_hood_customs.lua"
local LOADER = ROOT .. "/loader.lua"
local EXPECTED_URL = "https://raw.githubusercontent.com/haltorillshoot/juju-addon/main/dist/jhc_hood_customs.lua"

if not read(BUNDLE) or not read(LOADER) then
  T.test("loader tests need dist/ built (python tools/build.py)", function() error("dist or loader.lua missing") end)
  return true
end

-- run loader.lua inside a mocked executor
local function run_loader(opts)
  opts = opts or {}
  local sim = Mock.Sim.new()
  local g = Mock.Game.new(sim)
  local me = g:add_player("Me", 1, true)
  g:spawn(me)
  local J = Mock.new_juju(sim, g)
  local env = Mock.env(sim, g, J, { drawing = Mock.new_drawing(), no_juju = opts.no_juju })
  local urls = {}
  if opts.no_http_get then
    env.request = function(req) urls[#urls + 1] = req.Url; return { Body = read(BUNDLE) } end
  else
    g.game.HttpGet = function(_, url)
      urls[#urls + 1] = url
      if opts.http_error then error("HTTP 404") end
      return opts.body or read(BUNDLE)
    end
  end
  if opts.config then env.genv.JHC_CONFIG = opts.config end
  local fake_os = { clock = sim.clock, time = os.time, date = os.date }
  local genv
  genv = setmetatable({}, { __index = function(_, k)
    if k == "os" then return fake_os end
    if k == "loadstring" then
      return function(src, name)
        local f, e = loadstring(src, name)
        if f then setfenv(f, genv) end          -- like an executor: loaded chunks share its environment
        return f, e
      end
    end
    local v = env[k]
    if v ~= nil then return v end
    return _G[k]
  end })
  local chunk = assert(loadfile(LOADER))
  setfenv(chunk, genv)
  local ok, result = pcall(chunk)
  return { ok = ok, inst = result, urls = urls, env = env, J = J, sim = sim, g = g }
end

local function output(r) return table.concat(r.env.output, "\n") end

T.test("downloads the pinned URL, compiles and starts the addon", function()
  local r = run_loader()
  T.ok(r.ok, tostring(r.inst))
  T.ok(type(r.inst) == "table", "loader should return the addon instance")
  T.eq(#r.urls, 1)
  T.eq(r.urls[1], EXPECTED_URL)
  T.eq(r.J.tabs, 1, "menu was built")
  T.contains(output(r), "loaded")
  r.J.unload()
  T.ok(r.inst.dead)
end)

T.test("getgenv().JHC_CONFIG set before the loader reaches the addon", function()
  local r = run_loader({ config = { scope = "all", hud = false } })
  T.ok(type(r.inst) == "table")
  T.eq(r.inst.cfg.scope, "all")
  T.eq(r.inst.cfg.hud, false)
end)

T.test("falls back to request() when game:HttpGet is not available", function()
  local r = run_loader({ no_http_get = true })
  T.ok(type(r.inst) == "table", output(r))
  T.eq(r.urls[1], EXPECTED_URL)
end)

T.test("outside Juju (no juju global) it stops before downloading anything", function()
  local r = run_loader({ no_juju = true })
  T.ok(r.ok)
  T.is_nil(r.inst)
  T.eq(#r.urls, 0)
  T.contains(output(r), "juju")
end)

T.test("download failure is reported, nothing runs", function()
  local r = run_loader({ http_error = true })
  T.ok(r.ok); T.is_nil(r.inst)
  T.contains(output(r), "could not download")
  T.eq(r.J.tabs, 0)
end)

T.test("a wrong payload (e.g. an HTML error page) is rejected by the sanity check", function()
  local r = run_loader({ body = "<html>" .. string.rep("not found ", 300) .. "</html>" })
  T.ok(r.ok); T.is_nil(r.inst)
  T.contains(output(r), "could not download a valid bundle")
  T.eq(r.J.tabs, 0)
end)

T.test("a bundle that does not compile is reported", function()
  local r = run_loader({ body = "-- JHC Hit Checker for Juju\n" .. string.rep("-- pad\n", 300) .. "this is not lua ((" })
  T.ok(r.ok); T.is_nil(r.inst)
  T.contains(output(r), "failed to compile")
end)

T.test("a bundle that errors while starting is reported, not thrown", function()
  local r = run_loader({ body = "-- JHC Hit Checker for Juju\n" .. string.rep("-- pad\n", 300) .. "error('boom')" })
  T.ok(r.ok); T.is_nil(r.inst)
  T.contains(output(r), "failed to start")
  T.contains(output(r), "boom")
end)

return true
