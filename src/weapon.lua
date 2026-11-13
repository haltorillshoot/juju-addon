-- weapon.lua
-- Weapon identification. Pure functions, no Roblox access.
--
-- The Juju docs say nothing about weapons, and the real in-game tool name of the Double Barrel
-- Shotgun is UNVERIFIED. Identification is therefore by normalised name (letters only, lower
-- case) against cfg.weapon_aliases, which the user can edit.

local U = require("util")

local W = {}

W.NONE = { key = "none", name = "none", is_dbs = false }

function W.identify(name, cfg)
  local key = U.normalize_name(name)
  if key == "" then key = "unknown" end
  local is_dbs = false
  if key ~= "unknown" then
    local aliases = cfg.weapon_aliases
    for i = 1, #aliases do
      local a = aliases[i]
      if a ~= "" and string.find(key, a, 1, true) then
        is_dbs = true
        break
      end
    end
  end
  return {
    key = key,
    name = (type(name) == "string" and name ~= "") and name or "?",
    is_dbs = is_dbs,
  }
end

-- Splits "CurrentAmmo", "ammo_count", "Max-Clip" into lower-case words.
local function words_of(name)
  if type(name) ~= "string" then return {} end
  local spaced = name:gsub("(%l)(%u)", "%1 %2"):gsub("[^%a]+", " ")
  local out = {}
  for w in string.gmatch(string.lower(spaced), "%a+") do out[#out + 1] = w end
  return out
end

-- Words that mark a CONSTANT or a stock rather than the live counter ("BulletSpeed",
-- "MagazineSize", "ShellCapacity", "ReserveAmmo", "MaxAmmo"): any word starting with one of
-- them disqualifies the name.
local NOT_LIVE = { "max", "size", "capacity", "speed", "damage", "rate", "reserve", "total", "spare",
  "stock", "limit" }

-- True when a numeric value/attribute name looks like CURRENT ammo.
-- A pattern must be the start or the end of a word ("Damage" must not match "mag").
-- Even then the source is only TRUSTED after it has been seen to decrease on a shot (world.lua).
function W.is_ammo_name(name, cfg)
  local words = words_of(name)
  if #words == 0 then return false end
  for i = 1, #words do
    for j = 1, #NOT_LIVE do
      if string.sub(words[i], 1, #NOT_LIVE[j]) == NOT_LIVE[j] then return false end
    end
  end
  local pats = cfg.ammo_patterns
  for i = 1, #words do
    local w = words[i]
    for j = 1, #pats do
      local p = pats[j]
      if string.sub(w, 1, #p) == p or (#w >= #p and string.sub(w, -#p) == p) then return true end
    end
  end
  return false
end

return W
