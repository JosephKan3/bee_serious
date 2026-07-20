--[[
  Bee Keeper Nav
  ---------------
  Direct-flight movement for a Drone hovering at one fixed Y level, plus
  dead-reckoning position tracking. Modeled on GTNH-CropAutomation's
  gps.lua (a proven, production pattern) but adapted for continuous Drone
  flight instead of a Robot's discrete forward()/turn() steps -- per your
  call, no stepwise movement: gotoXZ commands the drone straight to a
  target in one shot via the Drone's own physics (component.drone.move
  sets a target offset; the drone accelerates/decelerates toward it on its
  own, not fully instant).

  CONFIRMED FROM SOURCE (li.cil.oc.server.component.Drone):
    - move(dx,dy,dz): adds a RELATIVE offset to the drone's internal
      target position. Not a teleport -- the drone flies there over time.
    - getOffset(): remaining distance to that target, in blocks. Poll this
      to know when you've arrived (this module uses arrivalThreshold).
  There is no absolute-position API without a Navigation Upgrade + map
  item (which most drones won't have) -- so, like the crop bot, position
  is tracked purely by dead reckoning from a known home/charger point.
  This drifts only if a move is interrupted/blocked; see stuck-detection
  below.

  Y IS FIXED: per your requirement, this never issues a dy != 0 move on
  its own. Altitude is set once (see Nav.setHome) and everything else is
  X/Z only. If you need the drone to change altitude (e.g. to actually
  reach the charger, or to fly over an obstacle), do that explicitly with
  Nav.setAltitude -- it's deliberately not automatic.
--]]

local M = {}
local Status = require("bee_keeper_status")

local function drone() return require("component").drone end
local function computer() return require("computer") end

-- ============================================================
-- State
-- ============================================================

local pos = { x = 0, z = 0 }  -- dead-reckoned position relative to home
local homePos = { x = 0, z = 0 }
local y = nil  -- the fixed flight altitude; set via Nav.setHome/setAltitude

M.arrivalThreshold = 0.35     -- blocks; getOffset() below this counts as "arrived"
M.stuckTimeout = 8            -- seconds with no progress before treating a move as stuck
M.pollInterval = 0.2          -- seconds between getOffset() polls

function M.getPos() return { x = pos.x, z = pos.z } end
function M.getAltitude() return y end

-- Call once at startup, at the drone's actual starting position (e.g. on
-- its charger). Establishes the origin for all dead-reckoned coordinates
-- and locks in the fixed flight altitude.
function M.setHome(altitude)
  pos = { x = 0, z = 0 }
  homePos = { x = 0, z = 0 }
  y = altitude
end

-- Explicit altitude change (the one deliberate exception to "Y is fixed").
-- dy is a relative offset, same semantics as gotoXZ's dx/dz.
function M.setAltitude(newY)
  if y == nil then
    error("Nav.setHome must be called before setAltitude")
  end
  local dy = newY - y
  if dy ~= 0 then
    drone().move(0, dy, 0)
    local waited = 0
    while drone().getOffset() > M.arrivalThreshold do
      os.sleep(M.pollInterval)
      waited = waited + M.pollInterval
      if waited > M.stuckTimeout then
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

-- Flies directly (single move, not stepwise) to the given X/Z, at the
-- fixed altitude. Returns true on arrival, or false + reason if it got
-- stuck (no progress for stuckTimeout seconds -- most likely an obstacle
-- in the way, since drones aren't noclip).
function M.gotoXZ(targetX, targetZ)
  if y == nil then
    error("Nav.setHome must be called before gotoXZ")
  end

  local dx = targetX - pos.x
  local dz = targetZ - pos.z
  if dx == 0 and dz == 0 then
    return true
  end

  Status.setStep(string.format("Flying to (%d,%d)", targetX, targetZ))
  drone().move(dx, 0, dz)

  local lastOffset = drone().getOffset()
  local stuckFor = 0
  while true do
    os.sleep(M.pollInterval)
    local offset = drone().getOffset()

    if offset <= M.arrivalThreshold then
      pos = { x = targetX, z = targetZ }
      return true
    end

    -- Progress check: if the remaining distance isn't shrinking, we're
    -- probably blocked by something solid.
    if offset < lastOffset - 0.01 then
      stuckFor = 0
    else
      stuckFor = stuckFor + M.pollInterval
    end
    lastOffset = offset

    if stuckFor > M.stuckTimeout then
      local reason = "stuck_at_offset_" .. string.format("%.1f", offset)
      Status.setStep(string.format("STUCK flying to (%d,%d): %s", targetX, targetZ, reason))
      return false, reason
    end
  end
end

function M.gotoHome()
  return M.gotoXZ(homePos.x, homePos.z)
end

-- ============================================================
-- Site visiting order: nearest-neighbor from the current position, not
-- config list order -- minimizes total travel per cycle (your call).
-- ============================================================

local function dist2(ax, az, bx, bz)
  local dx, dz = ax - bx, az - bz
  return dx * dx + dz * dz
end

-- sites: array of { x=.., z=.., ... }. Returns a NEW array in
-- nearest-neighbor visiting order starting from the drone's current
-- position (greedy -- not the optimal TSP tour, but cheap and good enough
-- for a handful of apiaries revisited every cycle).
function M.orderByProximity(sites)
  local remaining = {}
  for i, s in ipairs(sites) do remaining[i] = s end
  local ordered = {}
  local cx, cz = pos.x, pos.z

  while #remaining > 0 do
    local bestIdx, bestDist = 1, math.huge
    for i, s in ipairs(remaining) do
      local d = dist2(cx, cz, s.x, s.z)
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
-- Charging (mirrors action.lua's charge() -- computer.energy() is generic
-- OC API, works the same for a Drone as a Robot)
-- ============================================================

function M.needCharge(threshold)
  threshold = threshold or 0.2
  return computer().energy() / computer().maxEnergy() < threshold
end

function M.isFullyCharged()
  return computer().energy() / computer().maxEnergy() > 0.99
end

-- Flies home and waits until charged. chargerXZ defaults to home (0,0) --
-- pass an explicit position if the charger isn't where Nav.setHome was
-- called.
function M.chargeAtHome(chargerXZ)
  local target = chargerXZ or homePos
  M.gotoXZ(target.x, target.z)
  Status.setStep("Charging")
  while not M.isFullyCharged() do
    os.sleep(1)
  end
end

return M
