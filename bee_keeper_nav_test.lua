--[[
  Mock-based tests for bee_keeper_nav.lua: pure geometry (orderByProximity)
  plus gotoXZ's turn-optimal pathing/arrival/stuck detection against a
  fake Robot that independently tracks its OWN ground-truth position and
  facing (using the same 1=+Z/2=+X/3=-Z/4=-X convention bee_keeper_nav.lua
  documents), so these tests catch nav.lua's internal facing tracking
  actually drifting from reality, not just being self-consistent.
--]]

local robotState = {
  x = 0, z = 0, y = 0,
  facing = 1,
  blocked = false,   -- forward() always fails
  blockAfter = nil,  -- forward() succeeds this many times, then fails
  forwardCount = 0,
  callLog = {},       -- ordered log of "forward"/"turnLeft"/"turnRight" for sequencing checks
  energy = 50,
}

local function wrapFacing(f) return ((f - 1) % 4) + 1 end

package.loaded["component"] = {
  robot = {
    forward = function()
      table.insert(robotState.callLog, "forward")
      if robotState.blocked then return false end
      if robotState.blockAfter and robotState.forwardCount >= robotState.blockAfter then return false end
      robotState.forwardCount = robotState.forwardCount + 1
      if robotState.facing == 1 then robotState.z = robotState.z + 1
      elseif robotState.facing == 2 then robotState.x = robotState.x + 1
      elseif robotState.facing == 3 then robotState.z = robotState.z - 1
      elseif robotState.facing == 4 then robotState.x = robotState.x - 1 end
      return true
    end,
    turnRight = function()
      table.insert(robotState.callLog, "turnRight")
      robotState.facing = wrapFacing(robotState.facing + 1)
      return true
    end,
    turnLeft = function()
      table.insert(robotState.callLog, "turnLeft")
      robotState.facing = wrapFacing(robotState.facing - 1)
      return true
    end,
    up = function() robotState.y = robotState.y + 1; return true end,
    down = function() robotState.y = robotState.y - 1; return true end,
  },
}

package.loaded["computer"] = {
  energy = function() return robotState.energy or 50 end,
  maxEnergy = function() return 100 end,
}

-- os.sleep doesn't exist outside OpenComputers -- stub it so
-- chargeAtHome's wait loop doesn't error.
os.sleep = function() end

local Nav = require("bee_keeper_nav")
Nav.MAX_RETRIES = 3 -- keep the stuck test fast

local failures = 0
local function check(name, cond, detail)
  if cond then
    print("OK   " .. name)
  else
    failures = failures + 1
    print("FAIL " .. name .. (detail and (" -- " .. detail) or ""))
  end
end

local function resetRobot()
  robotState.x, robotState.z, robotState.y = 0, 0, 0
  robotState.facing = 1
  robotState.blocked = false
  robotState.blockAfter = nil
  robotState.forwardCount = 0
  robotState.callLog = {}
end

-- ============================================================
-- Test: gotoXZ arrives normally, tracked position matches the mock's
-- independent ground truth
-- ============================================================

do
  resetRobot()
  Nav.setHome(70) -- locks altitude, resets tracked position to (0,0)
  local ok = Nav.gotoXZ(5, 3)
  check("gotoXZ reports success on normal arrival", ok == true)

  local pos = Nav.getPos()
  check("gotoXZ's tracked position matches the target", pos.x == 5 and pos.z == 3,
    string.format("pos=(%s,%s)", tostring(pos.x), tostring(pos.z)))
  check("gotoXZ's tracked position matches the mock's independent ground truth",
    pos.x == robotState.x and pos.z == robotState.z,
    string.format("tracked=(%d,%d) actual=(%d,%d)", pos.x, pos.z, robotState.x, robotState.z))
  check("gotoXZ never touched altitude (Y locked)", robotState.y == 0)
end

-- ============================================================
-- Test: gotoXZ from a non-origin position computes the correct relative
-- path (not an absolute move)
-- ============================================================

do
  resetRobot()
  Nav.setHome(70)
  Nav.gotoXZ(5, 3)
  robotState.callLog = {}
  Nav.gotoXZ(8, 3) -- +3 in X only, from the previous test's endpoint

  local forwardCount = 0
  for _, call in ipairs(robotState.callLog) do
    if call == "forward" then forwardCount = forwardCount + 1 end
  end
  check("gotoXZ only issues the 3 forward() steps actually needed", forwardCount == 3, "count=" .. forwardCount)
  check("gotoXZ ends at the correct absolute position", Nav.getPos().x == 8 and Nav.getPos().z == 3)
end

-- ============================================================
-- Test: turn-optimal pathing -- whichever axis needs the smaller turn
-- goes first (same heuristic as gps.lua's go())
-- ============================================================

do
  resetRobot()
  Nav.setHome(70) -- facing starts at 1 (+Z)
  robotState.callLog = {}
  -- Target requires +X (facing 2, 1 turnRight from facing 1) and +Z
  -- (facing 1, already facing that way, 0 turns) -- the Z leg costs
  -- less to turn to, so it should be attempted FIRST.
  Nav.gotoXZ(5, 5)

  local firstForwardIndex = nil
  for i, call in ipairs(robotState.callLog) do
    if call == "forward" and not firstForwardIndex then firstForwardIndex = i end
  end
  -- Zero turns needed before the first forward() means the cheaper (Z)
  -- leg went first, matching facing 1 already pointing +Z.
  check("cheaper-turn axis is attempted before the costlier one", firstForwardIndex == 1,
    "callLog=" .. table.concat(robotState.callLog, ","))
end

-- ============================================================
-- Test: gotoXZ reports stuck when forward() never succeeds, and tracked
-- position reflects real partial progress, not 0 and not the target
-- ============================================================

do
  resetRobot()
  Nav.setHome(70)
  robotState.blockAfter = 2 -- succeeds twice, then jams

  local ok, reason = Nav.gotoXZ(10, 0)
  check("gotoXZ reports failure when blocked", ok == false)
  check("gotoXZ gives a stuck reason", reason ~= nil and reason:match("^stuck") ~= nil, tostring(reason))
  check("tracked position reflects the 2 steps that actually succeeded, not 0 or the target",
    Nav.getPos().x == 2, "x=" .. tostring(Nav.getPos().x))
  check("tracked position matches the mock's ground truth even after getting stuck",
    Nav.getPos().x == robotState.x)
end

-- ============================================================
-- Test: setAltitude is the one path that touches Y, gotoXZ never does
-- ============================================================

do
  resetRobot()
  Nav.setHome(70)
  local ok = Nav.setAltitude(73)
  check("setAltitude succeeds and reports the new altitude", ok == true and Nav.getAltitude() == 73)
  check("setAltitude actually moved the robot up 3 blocks", robotState.y == 3, "y=" .. robotState.y)

  Nav.gotoXZ(4, 4)
  check("gotoXZ never changes altitude once set", robotState.y == 3, "y=" .. robotState.y)
end

-- ============================================================
-- Test: orderByProximity does nearest-neighbor ordering from current pos
-- ============================================================

do
  resetRobot()
  Nav.setHome(70) -- back to (0,0)

  local sites = {
    { name = "far", x = 100, z = 100 },
    { name = "near", x = 1, z = 1 },
    { name = "mid", x = 10, z = 10 },
  }
  local ordered = Nav.orderByProximity(sites)
  check("orderByProximity visits the nearest site first", ordered[1].name == "near", ordered[1].name)
  check("orderByProximity visits the middle site second", ordered[2].name == "mid", ordered[2].name)
  check("orderByProximity visits the farthest site last", ordered[3].name == "far", ordered[3].name)
end

do
  -- From a position closer to "far" than "near", the greedy order should
  -- flip -- confirms it's actually using the CURRENT position, not just
  -- sorting by distance from the origin.
  resetRobot()
  Nav.setHome(70)
  Nav.gotoXZ(90, 90)

  local sites = {
    { name = "far-from-origin-but-close-now", x = 100, z = 100 },
    { name = "near-origin-but-far-now", x = 1, z = 1 },
  }
  local ordered = Nav.orderByProximity(sites)
  check("orderByProximity uses the robot's CURRENT position, not the origin",
    ordered[1].name == "far-from-origin-but-close-now", ordered[1].name)
end

-- ============================================================
-- Test: needCharge / isFullyCharged thresholds
-- ============================================================

do
  robotState.energy = 10 -- 10%
  check("needCharge true when below threshold", Nav.needCharge(0.2) == true)
  check("isFullyCharged false when not full", Nav.isFullyCharged() == false)

  robotState.energy = 100
  check("needCharge false when full", Nav.needCharge(0.2) == false)
  check("isFullyCharged true at 100%", Nav.isFullyCharged() == true)
end

print("")
if failures == 0 then
  print("ALL TESTS PASSED")
else
  print(failures .. " TEST(S) FAILED")
  os.exit(1)
end
