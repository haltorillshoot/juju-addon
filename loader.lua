--[[
  JHC Hit Checker - loader for Juju (Hood Customs)

  Run this script from Juju. It downloads the addon bundle from the GitHub repo and runs it.

  NOTES
  * HttpGet / request / loadstring are executor functions, NOT part of the Juju docs. If your
    executor lacks them, download dist/jhc_hood_customs.lua yourself and load that file instead.
  * You are running code fetched from the internet. To be safe, set REF below to a specific commit
    id (a 40-character SHA) instead of "main": then the code can never change under you.
  * Optional settings (set BEFORE this script runs), for example:
        getgenv().JHC_CONFIG = { scope = "target", hud = true }
    Every key is listed in src/config.lua.
]]

local REPO = "haltorillshoot/juju-addon"
local REF  = "main"          -- branch, tag or (recommended) commit SHA
local URL  = "https://raw.githubusercontent.com/" .. REPO .. "/" .. REF .. "/dist/jhc_hood_customs.lua"
local MARK = "JHC Hit Checker for Juju"      -- sanity check on what was downloaded

local function say(msg) (warn or print)("[JHC loader] " .. tostring(msg)) end

if type(juju) ~= "table" then
  say("global 'juju' not found - run this from inside Juju.")
  return
end

local source
local okGet, resGet = pcall(function() return game:HttpGet(URL) end)
if okGet and type(resGet) == "string" then
  source = resGet
else
  local req = (type(request) == "function" and request) or (type(http_request) == "function" and http_request)
  if req then
    local okReq, resp = pcall(req, { Url = URL, Method = "GET" })
    if okReq and type(resp) == "table" and type(resp.Body) == "string" then source = resp.Body end
  end
end

if type(source) ~= "string" or #source < 1000 or not string.find(source, MARK, 1, true) then
  say("could not download a valid bundle from " .. URL)
  return
end

local chunk, err = loadstring(source, "=jhc_hood_customs")
if not chunk then
  say("bundle failed to compile: " .. tostring(err))
  return
end

local ok, result = pcall(chunk)
if not ok then
  say("bundle failed to start: " .. tostring(result))
  return
end
return result
