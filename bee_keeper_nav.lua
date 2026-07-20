--[[
  Bee Keeper Nav
  ---------------
  Discrete step-based movement for a ROBOT (confirmed via
  component.isAvailable("drone")==false / ("robot")==true on the actual
  hardware -- this replaces an earlier Drone-flight version, which
  doesn't apply here: a Robot has no component.drone.move()/getOffset()
  at all). Modeled directly on GTNH-CropAutomation's gps.lua -- a proven,
  production pattern for exactly this: Robot movement, one block at a
  time, turn-optimal pathing, hovering at one fixed Y level.

  Position tracking is EXACT here (unlike a Drone's dead reckoning):
  robot.forward()/turnLeft()/etc. each either fully succeed or fully
  fail, there's no "interrupted mid-flight" ambiguity to account for.

  Y IS FIXED: per the original requirement, this never issues an up()/
  down() call on its own. Altitude is set once (Nav.setHome) and
  everything else is X/Z only; Nav.setAltitude is the one deliberate
  exception.

  gotoXZ is still the one entry point everything else calls, so
  bee_keeper_manager.lua/bee_keeper_setup.lua needed ZERO changes for
  this swap -- they only ever call Nav.gotoXZ/getPos/orderByProximity,
  never touch movement primitives directly. (bee_keeper_setup.lua's
  corner-preview light flash is the one place that DOES touch a
  Drone-only API directly -- see its own comments for how that degrades
  on a Robot.)
--]]

local M = {}
local Status = require("bee_keeper_status")

-- The "robot" LIBRARY (require("robot")), NOT component.robot -- the raw
-- component doesn't expose forward()/turnLeft()/turnRight()/up()/down()
-- by those names at all (confirmed on real hardware: "attempt to call a
-- nil value (field 'turnRight')"). require("robot") is OpenComputers'
-- documented high-level movement API and is what GTNH-CropAutomation's
-- gps.lua (the pattern this file is modeled on) actually uses.
local function robot() return require("robot") end
local function computer() return require("computer") end

-- ============================================================
-- State
-- ============================================================

local pos = { x = 0, z = 0 }  -- exact position relative to home
local homePos = { x = 0, z = 0 }
local homeSet = false  -- whether Nav.setHome has been called yet -- tracked
                        -- separately from `y` since nil is a legitimate
                        -- altitude value (setHome(nil): "wherever the robot
                        -- currently is, don't bother tracking Y explicitly")
local y = nil  -- the fixed flight altitude; set via Nav.setHome/setAltitude

-- Internal facing convention, purely for computing turn deltas -- doesn't
-- need to match OC's `sides` numbering. 1=+Z, 2=+X, 3=-Z, 4=-X.
local facing = 1

-- Consecutive failed forward()/up()/down() attempts (a mob, a placed
-- block, anything transient-or-not in the way) before giving up and
-- reporting stuck, rather than retrying forever like gps.lua's
-- safeForward() does.
M.MAX_RETRIES = 20

function M.getPos() return { x = pos.x, z = pos.z } end
function M.getAltitude() return y end
function M.getFacing() return facing end

-- Call once at startup, at the robot's actual starting position (e.g. on
-- its charger). Establishes the origin for all tracked coordinates and
-- locks in the fixed operating altitude.
function M.setHome(altitude)
  pos = { x = 0, z = 0 }
  homePos = { x = 0, z = 0 }
  facing = 1
  y = altitude
  homeSet = true
end

-- Explicit altitude change (the one deliberate exception to "Y is
-- fixed"). dy is a relative offset, same semantics as gotoXZ's target.
-- Requires an actual known altitude (i.e. Nav.setHome was called with a
-- real number, not nil) since there's no starting value to offset from
-- otherwise.
function M.setAltitude(newY)
  if not homeSet then
    error("Nav.setHome must be called before setAltitude")
  end
  if y == nil then
    error("Nav.setAltitude needs a known starting altitude -- Nav.setHome was called with altitude=nil")
  end
  local dy = newY - y
  local step = dy > 0 and robot().up or robot().down
  for _ = 1, math.abs(dy) do
    local attempts = 0
    while not step() do
      attempts = attempts + 1
      if attempts > M.MAX_RETRIES then
        return false, "stuck_changing_altitude"
      end
    end
  end
  y = newY
  return true
end

-- ============================================================
-- Movement
-- ============================================================

local function turnTo(target)
  local delta = (target - facing) % 4
  if delta <= 2 then
    for _ = 1, delta do robot().turnRight() end
  else
    for _ = 1, 4 - delta do robot().turnLeft() end
  end
  facing = target
end

local function turningCost(target)
  local delta = (target - facing) % 4
  return math.min(delta, 4 - delta)
end

-- Steps forward up to `count` times in the CURRENT facing. Returns how
-- many steps actually succeeded (so a partial failure mid-leg can still
-- be reflected accurately in tracked position) plus a reason if it
-- didn't complete all of them.
local function stepForward(count)
  local completed = 0
  for _ = 1, count do
    local attempts = 0
    while not robot().forward() do
      attempts = attempts + 1
      if attempts > M.MAX_RETRIES then
        return completed, "stuck_moving_forward"
      end
    end
    completed = completed + 1
  end
  return completed, nil
end

-- Walks directly to the given X/Z at the fixed altitude, turn-optimal
-- (does whichever axis needs the smaller turn first -- same heuristic as
-- gps.lua's go()). Returns true on arrival, or false + reason if it got
-- stuck partway (position is updated to reflect exactly how far it
-- actually got, not silently left wrong).
function M.gotoXZ(targetX, targetZ)
  if not homeSet then
    error("Nav.setHome must be called before gotoXZ")
  end

  local dx = targetX - pos.x
  local dz = targetZ - pos.z
  if dx == 0 and dz == 0 then
    return true
  end

  Status.setStep(string.format("Walking to (%d,%d)", targetX, targetZ))

  local path = {}
  if dx > 0 then path[#path + 1] = { 2, dx }
  elseif dx < 0 then path[#path + 1] = { 4, -dx } end
  if dz > 0 then path[#path + 1] = { 1, dz }
  elseif dz < 0 then path[#path + 1] = { 3, -dz } end

  if #path == 2 and turningCost(path[2][1]) < turningCost(path[1][1]) then
    path[1], path[2] = path[2], path[1]
  end

  local traveled = { x = pos.x, z = pos.z }
  for _, leg in ipairs(path) do
    turnTo(leg[1])
    local completed, reason = stepForward(leg[2])

    if leg[1] == 2 then traveled.x = traveled.x + completed
    elseif leg[1] == 4 then traveled.x = traveled.x - completed
    elseif leg[1] == 1 then traveled.z = traveled.z + completed
    elseif leg[1] == 3 then traveled.z = traveled.z - completed end

    if reason then
      pos = traveled
      Status.setStep(string.format("STUCK walking to (%d,%d): %s", targetX, targetZ, reason))
      return false, reason
    end
  end

  pos = { x = targetX, z = targetZ }
  return true
end

function M.gotoHome()
  return M.gotoXZ(homePos.x, homePos.z)
end

-- ============================================================
-- Site visiting order: nearest-neighbor from the current position, not
-- config list order -- minimizes total travel per cycle. Manhattan
-- distance (not Euclidean) since that's what a grid-walker actually
-- pays for each site.
-- ============================================================

local function dist(ax, az, bx, bz)
  return math.abs(ax - bx) + math.abs(az - bz)
end

-- sites: array of { x=.., z=.., ... }. Returns a NEW array in
-- nearest-neighbor visiting order starting from the robot's current
-- position (greedy -- not the optimal TSP tour, but cheap and good
-- enough for a handful of apiaries revisited every cycle).
function M.orderByProximity(sites)
  local remaining = {}
  for i, s in ipairs(sites) do remaining[i] = s end
  local ordered = {}
  local cx, cz = pos.x, pos.z

  while #remaining > 0 do
    local bestIdx, bestDist = 1, math.huge
    for i, s in ipairs(remaining) do
      local d = dist(cx, cz, s.x, s.z)
      if d < bestDist then
        bestDist = d
        bestIdx = i
      end
    end
    local chosen = table.remove(remaining, bestIdx)
    table.insert(ordered, chosen)
    cx, cz = chosen.x, chosen.z
  end

  return ordered
end

-- ============================================================
-- Charging (mirrors action.lua's charge() -- computer.energy() is
-- generic OC API, unaffected by Robot vs Drone)
-- ============================================================

function M.needCharge(threshold)
  threshold = threshold or 0.2
  return computer().energy() / computer().maxEnergy() < threshold
end

function M.isFullyCharged()
  return computer().energy() / computer().maxEnergy() > 0.99
end

-- Walks home and waits until charged. chargerXZ defaults to home (0,0)
-- -- pass an explicit position if the charger isn't where Nav.setHome
-- was called.
function M.chargeAtHome(chargerXZ)
  local target = chargerXZ or homePos
  M.gotoXZ(target.x, target.z)
  Status.setStep("Charging")
  while not M.isFullyCharged() do
    os.sleep(1)
  end
end

return M
