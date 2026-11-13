-- util.lua
-- Small dependency-free helpers. Written in the common subset of Lua 5.1 / LuaJIT / Luau
-- (no `continue`, no compound assignment, no type annotations) so the same file runs in the
-- test interpreter and inside Juju.

local U = {}

U.unpack = table.unpack or unpack

function U.clamp(v, lo, hi)
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

function U.is_finite(n)
  return type(n) == "number" and n == n and n ~= math.huge and n ~= -math.huge
end

function U.clear(t)
  for k in pairs(t) do t[k] = nil end
end

function U.shallow_copy(t)
  local r = {}
  for k, v in pairs(t) do r[k] = v end
  return r
end

function U.count(t)
  local n = 0
  for _ in pairs(t) do n = n + 1 end
  return n
end

-- Lower-case, letters only. "[Double-Barrel SG] - 2 | 2" -> "doublebarrelsg".
-- Digits are dropped on purpose: some games append ammo counts to the tool name.
function U.normalize_name(s)
  if type(s) ~= "string" then return "" end
  return (string.lower(s):gsub("[^a-z]", ""))
end

-- ---------------------------------------------------------------------------------------
-- Fixed-size ring buffer. get(1) is the oldest element, get(size()) the newest.
-- ---------------------------------------------------------------------------------------
local Ring = {}
Ring.__index = Ring

function Ring.new(cap)
  if type(cap) ~= "number" or cap < 1 then cap = 1 end
  return setmetatable({ cap = math.floor(cap), buf = {}, head = 0, n = 0 }, Ring)
end

function Ring:push(v)
  self.head = self.head % self.cap + 1
  self.buf[self.head] = v
  if self.n < self.cap then self.n = self.n + 1 end
end

function Ring:size() return self.n end

function Ring:get(i)
  if i < 1 or i > self.n then return nil end
  return self.buf[(self.head - self.n + i - 1) % self.cap + 1]
end

function Ring:last() return self:get(self.n) end

function Ring:to_array()
  local r = {}
  for i = 1, self.n do r[i] = self:get(i) end
  return r
end

function Ring:clear()
  self.buf = {}
  self.head = 0
  self.n = 0
end

U.Ring = Ring

-- ---------------------------------------------------------------------------------------
-- Small statistics helpers (nearest-rank percentiles; arrays are not modified).
-- ---------------------------------------------------------------------------------------
function U.percentile(arr, p)
  local n = #arr
  if n == 0 then return nil end
  local c = {}
  for i = 1, n do c[i] = arr[i] end
  table.sort(c)
  local rank = math.ceil(p / 100 * n)
  if rank < 1 then rank = 1 end
  if rank > n then rank = n end
  return c[rank]
end

function U.median(arr) return U.percentile(arr, 50) end

function U.mean(arr)
  local n = #arr
  if n == 0 then return nil end
  local s = 0
  for i = 1, n do s = s + arr[i] end
  return s / n
end

-- ---------------------------------------------------------------------------------------
-- Bag: keyed connection manager.
--   * set() on an existing key disconnects the old connection first -> no duplicate listeners
--   * every callback is wrapped in pcall; errors go to on_error instead of killing the handler
--   * clear()/drop_prefix() disconnect deterministically
-- `connector(signal, fn)` is supplied by the host (juju.create_connection or :Connect).
-- ---------------------------------------------------------------------------------------
local Bag = {}
Bag.__index = Bag

function Bag.new(connector, on_error)
  return setmetatable({ connector = connector, on_error = on_error, conns = {}, n = 0 }, Bag)
end

local function disconnect(conn)
  if conn ~= nil then
    pcall(function() conn:Disconnect() end)
  end
end

function Bag:set(key, signal, fn)
  self:drop(key)
  if signal == nil then return nil end
  local on_error = self.on_error
  local function guarded(...)
    local ok, err = pcall(fn, ...)
    if not ok and on_error then on_error(key, err) end
  end
  local ok, conn = pcall(self.connector, signal, guarded)
  if not ok or conn == nil then
    if on_error then on_error(key, "connect failed: " .. tostring(conn)) end
    return nil
  end
  self.conns[key] = conn
  self.n = self.n + 1
  return conn
end

function Bag:drop(key)
  local c = self.conns[key]
  if c ~= nil then
    self.conns[key] = nil
    self.n = self.n - 1
    disconnect(c)
  end
end

function Bag:drop_prefix(prefix)
  local keys = {}
  local len = #prefix
  for k in pairs(self.conns) do
    if string.sub(k, 1, len) == prefix then keys[#keys + 1] = k end
  end
  for i = 1, #keys do self:drop(keys[i]) end
end

function Bag:clear()
  local keys = {}
  for k in pairs(self.conns) do keys[#keys + 1] = k end
  for i = 1, #keys do self:drop(keys[i]) end
end

function Bag:has(key) return self.conns[key] ~= nil end
function Bag:size() return self.n end

U.Bag = Bag

-- ---------------------------------------------------------------------------------------
-- Logger: bounded history, optional console output when cfg.debug is true.
-- ---------------------------------------------------------------------------------------
function U.make_logger(cfg, sink, cap)
  local ring = Ring.new(cap or 200)
  local L = { ring = ring }
  function L.log(level, msg)
    ring:push({ level = level, msg = msg })
    if level == "error" or level == "warn" or cfg.debug then
      if sink then pcall(sink, "[" .. level .. "] " .. tostring(msg)) end
    end
  end
  return L
end

return U
