--[[
  Unit tests for bee_pool.lua -- the bounded, role-balanced pool manager.
--]]

package.path = package.path .. ";./?.lua"
local Pool = require("bee_pool")

local failures = 0
local function check(name, cond, detail)
  if cond then print("OK   " .. name)
  else failures = failures + 1; print("FAIL " .. name .. (detail and (" -- " .. detail) or "")) end
end

local function item(id, princess, fit, donor)
  return { id = id, p = princess, f = fit, donor = donor }
end
local function opts(over)
  local o = {
    isPrincess = function(i) return i.p end,
    fitness = function(i) return i.f end,
    maxPrincess = 2,
    maxDrone = 3,
    protect = function(i) return i.donor end,
  }
  for k, v in pairs(over or {}) do o[k] = v end
  return o
end
local function has(list, id)
  for _, i in ipairs(list) do if i.id == id then return true end end
  return false
end

-- Caps enforced per role.
do
  local pool = {
    item("p1", true, 5), item("p2", true, 4), item("p3", true, 3),
    item("d1", false, 9), item("d2", false, 8), item("d3", false, 7), item("d4", false, 6),
  }
  local keep, discard = Pool.balance(pool, opts())
  check("keeps top 2 princesses", has(keep, "p1") and has(keep, "p2") and not has(keep, "p3"))
  check("discards the weakest princess", has(discard, "p3"))
  check("keeps top 3 drones", has(keep, "d1") and has(keep, "d2") and has(keep, "d3") and not has(keep, "d4"))
  check("discards the weakest drone", has(discard, "d4"))
  check("kept total respects caps", #keep == 5, "keep=" .. #keep)
end

-- Protected bees are always kept and don't consume a cap slot.
do
  local pool = {
    item("dn", false, 0, true),                       -- protected donor, low fitness
    item("d1", false, 9), item("d2", false, 8), item("d3", false, 7), item("d4", false, 6),
    item("p1", true, 5), item("p2", true, 4),
  }
  local keep, discard = Pool.balance(pool, opts())
  check("protected donor kept despite lowest fitness", has(keep, "dn"))
  check("protection does not steal a drone cap slot (all 3 top drones kept)",
    has(keep, "d1") and has(keep, "d2") and has(keep, "d3"))
  check("weakest drone still discarded", has(discard, "d4"))
end

-- Over-protection guard: many carriers, only the FEW best survive the cap.
do
  local pool = {}
  for i = 1, 10 do pool[#pool + 1] = item("c" .. i, false, i) end -- all "carriers"
  local keep, discard = Pool.balance(pool, opts({ maxDrone = 3 }))
  local kept = 0
  for _, i in ipairs(keep) do kept = kept + 1 end
  check("only maxDrone carriers survive (no over-protection)", kept == 3, "kept=" .. kept)
  check("the 7 weakest carriers are discarded", #discard == 7, "discard=" .. #discard)
  check("survivors are the highest-fitness carriers",
    has(keep, "c10") and has(keep, "c9") and has(keep, "c8"))
end

-- Empty / role-count helpers.
do
  local keep, discard = Pool.balance({}, opts())
  check("empty pool -> empty keep/discard", #keep == 0 and #discard == 0)
  local p, d = Pool.roleCounts({ item("p", true, 1), item("d", false, 1), item("d2", false, 1) }, opts())
  check("roleCounts counts roles", p == 1 and d == 2, "p=" .. p .. " d=" .. d)
end

-- rng jitter never reorders genuinely different fitnesses.
do
  local pool = { item("hi", false, 100), item("lo", false, 0) }
  local keep = Pool.balance(pool, opts({ maxDrone = 1, rng = function() return 0.99 end }))
  check("rng jitter (0.5 max) can't flip a 100-point gap", has(keep, "hi"))
end

print("")
if failures == 0 then print("ALL TESTS PASSED")
else print(failures .. " TEST(S) FAILED"); os.exit(1) end
