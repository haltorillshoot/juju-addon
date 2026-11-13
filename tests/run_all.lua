-- tests/run_all.lua : runs every suite; returns the number of failures
-- args: [-v] [suite-prefix...]   e.g.  run_all.lua t03 t04
local T = require("tf")

local verbose = false
local only = {}
local skip_next = false
for i, a in ipairs(arg or {}) do
  if skip_next then
    skip_next = false
  elseif a == "-v" then
    verbose = true
  elseif a == "--bundle" then
    JHC_BUNDLE = arg[i + 1]        -- run integration tests against the shipped single file
    skip_next = true
  else
    only[#only + 1] = a
  end
end
if JHC_BUNDLE then print("*** integration tests run against bundle: " .. JHC_BUNDLE) end

local files = { "t01_init", "t02_api", "t03_hit", "t04_miss", "t05_stats", "t06_weapon", "t07_dbs",
  "t08_auto", "t09_diag", "t10_events", "t11_respawn", "t12_switch", "t13_config", "t14_ui",
  "t15_recovery", "t16_perf", "t17_latency", "t18_regress", "t19_loader", "t20_live", "t21_native" }

local t0 = os.clock()
for _, name in ipairs(files) do
  local run = (#only == 0)
  for _, p in ipairs(only) do
    if string.sub(name, 1, #p) == p then run = true end
  end
  if run then
    local ok, err = pcall(require, name)
    if not ok then
      if string.find(tostring(err), "module '" .. name .. "' not found", 1, true) then
        print("(skipping missing suite file " .. name .. ")")
      else
        T.suite("LOAD ERROR " .. name)
        T.test("suite file loads", function() error(err, 0) end)
      end
    end
  end
end

print(string.format("runtime: %s   elapsed: %.2fs", (jit and jit.version) or _VERSION, os.clock() - t0))
return T.summary(verbose)
