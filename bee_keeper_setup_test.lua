--[[
  Mock-based tests for bee_keeper_setup.lua: block classification during
  the area sweep, and that the sweep visits cells in boustrophedon
  (zigzag) order rather than always resetting to a corner between rows.
--]]

package.loaded["sides"] = { down = 1 }

local visitedCells = {}
local blocksByCell = {}  -- ["x:z"] = blockName
local invByCell = {}     -- ["x:z"] = { name = <invName>, size = <slotCount> }

local function cellKey()
  local pos = require("bee_keeper_nav").getPos()
  return pos.x .. ":" .. pos.z
end

package.loaded["component"] = {
  geolyzer = {
    analyze = function(side)
      return { name = blocksByCell[cellKey()] or "minecraft:air" }
    end,
  },
  -- Inventory the robot sees below at the current cell (nil for non-inventories),
  -- so scanArea can autodetect storage vs the honey drawer/barrel by name/size.
  inventory_controller = {
    getInventoryName = function(side) local e = invByCell[cellKey()]; return e and e.name end,
    getInventorySize = function(side) local e = invByCell[cellKey()]; return e and e.size end,
  },
  -- No robot/drone/computer registered -- isAvailable always false, so
  -- flyBorderPreview's light-flash/beep signaling never fires (both
  -- branches guarded by isAvailable checks), only its actual navigation.
  isAvailable = function() return false end,
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
    ["4:0"] = "extrautilities:trashcan",
  }

  local config = {
    apiaryBlockNames = { "forestry:apiary" },
    storageBlockNames = { "minecraft:chest" },
    trashBlockNames = { "extrautilities:trashcan" },
  }

  local result = Setup.scanArea(config, 5, 5)
  check("scanArea finds both apiaries", #result.apiarySites == 2, "found=" .. #result.apiarySites)
  check("scanArea finds the storage container", #result.storageSites == 1, "found=" .. #result.storageSites)
  check("scanArea finds the trash can", #result.trashSites == 1, "found=" .. #result.trashSites)

  local foundApiaryAt = {}
  for _, s in ipairs(result.apiarySites) do foundApiaryAt[s.x .. ":" .. s.z] = true end
  check("scanArea records the correct apiary positions", foundApiaryAt["1:1"] and foundApiaryAt["3:2"])

  check("scanArea records the correct storage position",
    result.storageSites[1].x == 0 and result.storageSites[1].z == 4)
  check("scanArea records the correct trash position",
    result.trashSites[1].x == 4 and result.trashSites[1].z == 0)
  check("trash and storage are classified separately, not lumped together",
    result.storageSites[1].x ~= result.trashSites[1].x or result.storageSites[1].z ~= result.trashSites[1].z)
end

-- ============================================================
-- Test: classifyBlock (pure) -- barrel/drawer -> honey, others -> bee storage
-- ============================================================

do
  local cfg = {
    apiaryBlockNames = { "Forestry:apiculture" },
    storageBlockNames = { "minecraft:chest" },
    trashBlockNames = { "ExtraUtilities:trashcan" },
    honeyStoreNames = { "barrel", "drawer" },
  }
  check("apiary by geolyzer name", Setup.classifyBlock(cfg, "Forestry:apiculture", nil, 12) == "apiary")
  check("trash by geolyzer name", Setup.classifyBlock(cfg, "ExtraUtilities:trashcan", nil, 1) == "trash")
  check("honey drawer by inventory name", Setup.classifyBlock(cfg, "somemod:block", "tile.fullDrawers1", 2) == "honey")
  check("honey barrel by block name", Setup.classifyBlock(cfg, "etfuturum:barrel", nil, nil) == "honey")
  check("apiarist chest -> bee storage (real inventory, not a barrel/drawer)",
    Setup.classifyBlock(cfg, "unknown:apiaristchest", "tile.for.apicultureChest", 125) == "storage")
  check("plain chest -> bee storage by block name", Setup.classifyBlock(cfg, "minecraft:chest", nil, 27) == "storage")
  check("any real inventory -> bee storage even if block name unknown",
    Setup.classifyBlock(cfg, "somemod:fancychest", "tile.fancyChest", 54) == "storage")
  check("non-inventory -> nil", Setup.classifyBlock(cfg, "minecraft:dirt", nil, nil) == nil)
  check("honey check beats generic storage (a barrel IS an inventory)",
    Setup.classifyBlock(cfg, "etfuturum:barrel", "tile.barrel", 1) == "honey")
end

-- ============================================================
-- Test: scanArea autoscans a mix -- 2 chests + apiarist chest -> bee storage,
-- a drawer -> honey, all in one sweep.
-- ============================================================

do
  visitedCells = {}
  blocksByCell = {
    ["1:1"] = "Forestry:apiculture",
    ["0:2"] = "minecraft:chest",
    ["2:0"] = "unknown:apiaristchest",
    ["3:3"] = "unknown:drawerblock",
  }
  invByCell = {
    ["0:2"] = { name = "tile.chest", size = 27 },
    ["2:0"] = { name = "tile.for.apicultureChest", size = 125 },
    ["3:3"] = { name = "tile.fullDrawers1", size = 2 },
  }
  local config = {
    apiaryBlockNames = { "Forestry:apiculture" },
    storageBlockNames = { "minecraft:chest" },
    trashBlockNames = { "ExtraUtilities:trashcan" },
    honeyStoreNames = { "barrel", "drawer" },
  }
  local result = Setup.scanArea(config, 4, 4)
  check("autoscan: 1 apiary", #result.apiarySites == 1, "found=" .. #result.apiarySites)
  check("autoscan: 2 bee-storage blocks (chest + apiarist chest)", #result.storageSites == 2,
    "found=" .. #result.storageSites)
  check("autoscan: 1 honey drawer", #result.honeySites == 1, "found=" .. #result.honeySites)
  check("autoscan: the drawer is the honey site", result.honeySites[1].x == 3 and result.honeySites[1].z == 3)
  invByCell = {} -- reset for later tests
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

-- ============================================================
-- Test: flyBorderPreview's far corner must match the LAST cell
-- sweepCells actually visits (width-1, depth-1), not (width, depth).
-- sweepCells iterates x=0..width-1, z=0..depth-1 (a 0-indexed WxD grid),
-- so (width, depth) is a full block PAST anything the real scan ever
-- reaches -- reported as a real bug: block placement based on the
-- preview's boundary could sit just outside the area actually swept,
-- never getting discovered by scanArea at all.
-- ============================================================

do
  visitedCells = {}
  blocksByCell = {}

  Setup.flyBorderPreview(5, 3) -- 5 wide (x), 3 deep (z)

  local farCorner = nil
  for _, cell in ipairs(visitedCells) do
    if cell[1] == 4 and cell[2] == 2 then farCorner = cell end
  end
  check("flyBorderPreview visits the actual far corner (4,2), matching sweepCells' last cell",
    farCorner ~= nil, "visited=" .. table.concat((function()
      local s = {}
      for _, c in ipairs(visitedCells) do table.insert(s, "(" .. c[1] .. "," .. c[2] .. ")") end
      return s
    end)(), ","))

  local overshoot = false
  for _, cell in ipairs(visitedCells) do
    if cell[1] >= 5 or cell[2] >= 3 then overshoot = true end
  end
  check("flyBorderPreview never visits a cell past what sweepCells(5,3) actually covers", not overshoot)
end

print("")
if failures == 0 then
  print("ALL TESTS PASSED")
else
  print(failures .. " TEST(S) FAILED")
  os.exit(1)
end
