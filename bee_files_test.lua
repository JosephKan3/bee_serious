--[[
  bee_files_test.lua -- guards the deployment manifest (bee_files.lua) against
  the exact bug that crashed the drone: a shipped module requiring another
  bee_* module that nobody ships. It proves the `code` list is CLOSED under
  require -- every bee_* module any shipped file requires is itself in the list.

  It also checks that every file the manifest names actually exists on disk, so
  a typo'd entry fails here instead of as a wget 404 on the drone.
--]]

package.path = package.path .. ";./?.lua"
local manifest = dofile("./bee_files.lua")

local failures = 0
local function check(name, cond, detail)
  if cond then print("OK   " .. name)
  else failures = failures + 1; print("FAIL " .. name .. (detail and (" -- " .. detail) or "")) end
end

local function readFile(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local s = f:read("*a")
  f:close()
  return s
end

-- Set of modules a require can resolve to: the `code` list plus any preserved
-- .lua (user config is downloaded-if-absent and always on disk at runtime).
local shipped = {}
local function addModule(file)
  local mod = file:match("^(.-)%.lua$")
  if mod then shipped[mod] = true end
end
for _, file in ipairs(manifest.code) do addModule(file) end
for _, file in ipairs(manifest.preserved) do addModule(file) end

-- 1. Every listed file (code + data + preserved defaults) exists on disk.
local function assertExists(file)
  check("exists on disk: " .. file, readFile("./" .. file) ~= nil)
end
for _, file in ipairs(manifest.code) do assertExists(file) end
for _, file in ipairs(manifest.data) do assertExists(file) end
-- Preserved: only the .lua defaults are shipped from the repo; .dat ones are
-- generated on first run and legitimately absent, so don't require them.
for _, file in ipairs(manifest.preserved) do
  if file:match("%.lua$") then assertExists(file) end
end

-- 2. Closure under require: scan each shipped code file for require("bee_*")
--    and assert every referenced module is itself shipped.
for _, file in ipairs(manifest.code) do
  local src = readFile("./" .. file)
  if src then
    for mod in src:gmatch("require%(%s*['\"](bee_[%w_]+)['\"]%s*%)") do
      check(file .. " requires shipped module " .. mod, shipped[mod],
        mod .. " is required by " .. file .. " but is not in bee_files.code")
    end
  end
end

if failures == 0 then
  print("\nALL PASS (" .. #manifest.code .. " code files, closure verified)")
else
  print("\n" .. failures .. " FAILURE(S)")
  os.exit(1)
end
