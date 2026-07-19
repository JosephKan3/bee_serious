--[[
  Mock-based tests for bee_keeper_setup.lua: block classification during
  the area sweep, and that the sweep visits cells in boustrophedon
  (zigzag) order rather than always resetting to a corner between rows.
--]]

package.loaded["sides"] = { down = 1 }

local visitedCells = {}
local blocksByCell = {}  -- ["x:z"] = blockName

package.loaded["component"] = {
  geolyzer = {
    analyze = function(side)
      local pos = require("bee_keeper_nav").getPos()
      local key = pos.x .. ":" .. pos.z
      return { name = blocksByCell[key] or "minecraft:air" }
    end,
  },
  drone = {
    getLightColor = function() return 0 end,
    setLightColor = function() end,
  },
}

package.loaded["bee_keeper_nav"] = (function()
  local pos = { x = 0, z = 0 }
  return {
    setHome = function() pos = { x = 0, z = 0 } end,
    getPos = function() return { x = pos.x, z = pos.z } end,
    gotoXZ = function(x, z)
      pos = { x = x, z = z }
      table.insert(visitedCells, { x, z })
      return true
    end,
    orderByProximity = function(sites) return sites end,
  }
end)()

os.sleep = function() end

local Setup = require("bee_keeper_setup")

local failures = 0
local function check(name, cond, detail)
  if cond then
    print("OK   " .. name)
  else
    failures = failures + 1
    print("FAIL " .. name .. (detail and (" -- " .. detail) or ""))
  end
end

-- ============================================================
-- Test: scanArea classifies apiary vs storage vs irrelevant blocks
-- ============================================================

do
  visitedCells = {}
  blocksByCell = {
    ["1:1"] = "forestry:apiary",
    ["3:2"] = "forestry:apiary",
    ["0:4"] = "minecraft:chest",
    ["2:2"] = "minecraft:dirt", -- irrelevant
  }

  local config = {
    apiaryBlockNames = { "forestry:apiary" },
    storageBlockNames = { "minecraft:chest" },
  }

  local result = Setup.scanArea(config, 5, 5)
  check("scanArea finds both apiaries", #result.apiarySites == 2, "found=" .. #result.apiarySites)
  check("scanArea finds the storage container", #result.storageSites == 1, "found=" .. #result.storageSites)

  local foundApiaryAt = {}
  for _, s in ipairs(result.apiarySites) do foundApiaryAt[s.x .. ":" .. s.z] = true end
  check("scanArea records the correct apiary positions", foundApiaryAt["1:1"] and foundApiaryAt["3:2"])

  check("scanArea records the correct storage position",
    result.storageSites[1].x == 0 and result.storageSites[1].z == 4)
end

-- ============================================================
-- Test: sweep visits every cell exactly once, in boustrophedon order
-- (alternating scan direction per column, not resetting to row 0 each time)
-- ============================================================

do
  visitedCells = {}
  blocksByCell = {}
  local config = { apiaryBlockNames = {}, storageBlockNames = {} }

  Setup.scanArea(config, 3, 4) -- 3 wide (x), 4 deep (z)

  check("sweep visits every cell exactly once", #visitedCells == 12, "visited=" .. #visitedCells)

  -- Column x=0 should go z: 0,1,2,3 (ascending); column x=1 should go
  -- z: 3,2,1,0 (descending) -- the zigzag that avoids a long reset flight
  -- back to z=0 between columns.
  local col0 = {}
  local col1 = {}
  for _, cell in ipairs(visitedCells) do
    if cell[1] == 0 then table.insert(col0, cell[2]) end
    if cell[1] == 1 then table.insert(col1, cell[2]) end
  end
  check("column 0 sweeps ascending", col0[1] == 0 and col0[4] == 3, table.concat(col0, ","))
  check("column 1 sweeps descending (zigzag, not reset)", col1[1] == 3 and col1[4] == 0, table.concat(col1, ","))
end

print("")
if failures == 0 then
  print("ALL TESTS PASSED")
else
  print(failures .. " TEST(S) FAILED")
  os.exit(1)
end
