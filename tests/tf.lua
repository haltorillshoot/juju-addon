-- tests/tf.lua : minimal test framework (suites, assertions, summary)
local T = { results = {}, suite_name = "?", failures = 0, passes = 0 }

function T.suite(name) T.suite_name = name end

function T.test(name, fn)
  local ok, err = xpcall(fn, function(e) return debug.traceback(tostring(e), 2) end)
  T.results[#T.results + 1] = { suite = T.suite_name, name = name, ok = ok, err = (not ok) and err or nil }
  if ok then T.passes = T.passes + 1 else T.failures = T.failures + 1 end
end

local function fmt(v) return type(v) == "string" and string.format("%q", v) or tostring(v) end

function T.eq(a, b, msg)
  if a ~= b then error((msg or "values differ") .. ": expected " .. fmt(b) .. ", got " .. fmt(a), 2) end
end
function T.neq(a, b, msg)
  if a == b then error((msg or "values equal") .. ": both " .. fmt(a), 2) end
end
function T.ok(v, msg) if not v then error(msg or "expected truthy", 2) end end
function T.falsy(v, msg) if v then error((msg or "expected falsy") .. ", got " .. fmt(v), 2) end end
function T.is_nil(v, msg) if v ~= nil then error((msg or "expected nil") .. ", got " .. fmt(v), 2) end end
function T.near(a, b, tol, msg)
  if type(a) ~= "number" or math.abs(a - b) > tol then
    error((msg or "not near") .. ": expected " .. tostring(b) .. " +/- " .. tostring(tol) .. ", got " .. tostring(a), 2)
  end
end
function T.contains(s, sub, msg)
  if type(s) ~= "string" or not string.find(s, sub, 1, true) then
    error((msg or "missing substring") .. ": " .. fmt(sub) .. " not in " .. fmt(s), 2)
  end
end
function T.raises(fn, msg)
  local ok = pcall(fn)
  if ok then error(msg or "expected an error", 2) end
end
function T.no_error(fn, msg)
  local ok, err = pcall(fn)
  if not ok then error((msg or "unexpected error") .. ": " .. tostring(err), 2) end
end

function T.summary(verbose)
  local suites, order = {}, {}
  for _, r in ipairs(T.results) do
    if not suites[r.suite] then suites[r.suite] = { pass = 0, fail = 0 }; order[#order + 1] = r.suite end
    if r.ok then suites[r.suite].pass = suites[r.suite].pass + 1 else suites[r.suite].fail = suites[r.suite].fail + 1 end
  end
  print("")
  print(string.rep("=", 78))
  for _, s in ipairs(order) do
    print(string.format("  %-54s pass %3d  fail %3d", s, suites[s].pass, suites[s].fail))
  end
  print(string.rep("-", 78))
  print(string.format("  TOTAL %d tests: %d passed, %d failed", T.passes + T.failures, T.passes, T.failures))
  print(string.rep("=", 78))
  for _, r in ipairs(T.results) do
    if not r.ok then
      print("FAIL [" .. r.suite .. "] " .. r.name)
      print("   " .. tostring(r.err):gsub("\n", "\n   "))
    elseif verbose then
      print("ok   [" .. r.suite .. "] " .. r.name)
    end
  end
  return T.failures
end

return T
