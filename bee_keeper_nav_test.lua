--[[
  Mock-based tests for bee_keeper_nav.lua: pure geometry (orderByProximity)
  plus gotoXZ's arrival/stuck detection against a fake drone that simulates
  either normal flight or a blocked (never-arrives) obstacle.
--]]

local droneState = {
  offset = 0,
  blocked = false,
  moveCalls = {},
}

package.loaded["component"] = {
  drone = {
    move = function(dx, dy, dz)
      table.insert(droneState.moveCalls, { dx = dx, dy = dy, dz = dz })
      if droneState.blocked then
        droneState.offset = 5 -- never shrinks -- simulates hitting an obstacle
      else
        droneState.offset = math.sqrt(dx * dx + dy * dy + dz * dz)
      end
    end,
    getOffset = function()
      if not droneState.blocked and droneState.offset > 0 then
        -- Simulate steady progress toward the target each poll.
        droneState.offset = math.max(0, droneState.offset - 1)
      end
      return droneState.offset
    end,
  },
}

package.loaded["computer"] = {
  energy = function() return droneState.energy or 50 end,
  maxEnergy = function() return 100 end,
}

-- os.sleep doesn't exist outside OpenComputers -- stub it so gotoXZ's
-- polling loop doesn't error (real durations don't matter for these tests).
os.sleep = function() end

local Nav = require("bee_keeper_nav")
-- pollInterval must stay NONZERO -- it's also the per-iteration increment
-- for stuck-detection (os.sleep is stubbed to a no-op above, so this
-- doesn't actually cause real delay, just keeps the stuck-timer math sane).
Nav.pollInterval = 0.05
Nav.stuckTimeout = 0.2 -- keep the stuck test fast (a handful of iterations)

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
-- Test: gotoXZ arrives normally and updates tracked position
-- ============================================================

do
  droneState.blocked = false
  droneState.offset = 0
  droneState.moveCalls = {}

  Nav.setHome(70) -- locks altitude, resets position to (0,0)
  local ok = Nav.gotoXZ(5, 3)
  check("gotoXZ reports success on normal arrival", ok == true)
  check("gotoXZ issued exactly one move() call (direct flight, not stepwise)", #droneState.moveCalls == 1,
    "calls=" .. #droneState.moveCalls)
  check("gotoXZ's move() kept dy at 0 (Y locked)", droneState.moveCalls[1].dy == 0)
  local pos = Nav.getPos()
  check("gotoXZ updated tracked position to the target", pos.x == 5 and pos.z == 3,
    string.format("pos=(%s,%s)", tostring(pos.x), tostring(pos.z)))
end

-- ============================================================
-- Test: gotoXZ from a non-origin position computes the correct relative
-- offset (not an absolute move)
-- ============================================================

do
  droneState.blocked = false
  droneState.offset = 0
  droneState.moveCalls = {}
  -- Nav still at (5,3) from the previous test.
  Nav.gotoXZ(8, 3)
  check("gotoXZ computes relative dx from current position", droneState.moveCalls[1].dx == 3,
    "dx=" .. tostring(droneState.moveCalls[1].dx))
  check("gotoXZ computes relative dz as 0 when z unchanged", droneState.moveCalls[1].dz == 0)
end

-- ============================================================
-- Test: gotoXZ reports stuck when offset never shrinks (obstacle)
-- ============================================================

do
  droneState.blocked = true
  droneState.offset = 5
  droneState.moveCalls = {}

  local ok, reason = Nav.gotoXZ(20, 20)
  check("gotoXZ reports failure when blocked", ok == false)
  check("gotoXZ gives a stuck reason", reason ~= nil and reason:match("^stuck") ~= nil, tostring(reason))
end

-- ============================================================
-- Test: orderByProximity does nearest-neighbor ordering from current pos
-- ============================================================

do
  droneState.blocked = false
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
  droneState.blocked = false
  droneState.offset = 0
  Nav.setHome(70)
  Nav.gotoXZ(90, 90)

  local sites = {
    { name = "far-from-origin-but-close-now", x = 100, z = 100 },
    { name = "near-origin-but-far-now", x = 1, z = 1 },
  }
  local ordered = Nav.orderByProximity(sites)
  check("orderByProximity uses the drone's CURRENT position, not the origin",
    ordered[1].name == "far-from-origin-but-close-now", ordered[1].name)
end

-- ============================================================
-- Test: needCharge / isFullyCharged thresholds
-- ============================================================

do
  droneState.energy = 10 -- 10%
  check("needCharge true when below threshold", Nav.needCharge(0.2) == true)
  check("isFullyCharged false when not full", Nav.isFullyCharged() == false)

  droneState.energy = 100
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
