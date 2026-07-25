--[[
  Tests for bee_combine.lua -- the serial-imprint combine planner. Unit checks on
  scoring/stage, plus an end-to-end convergence drive through the real genetics
  (bee_keeper_sim.crossRaw): the planner must reach a species-pure bee that is
  homozygous-good on EVERY trait, starting from X (bad) + an all-good foreign
  donor -- the case naive all-at-once selection plateaus on.
--]]

package.path = package.path .. ";./?.lua"
math.randomseed(7)
local Cfg = require("bee_trait_config")
local Sim = require("bee_keeper_sim")
local Combine = require("bee_combine")

local failures = 0
local function check(name, cond, detail)
  if cond then print("OK   " .. name)
  else failures = failures + 1; print("FAIL " .. name .. (detail and (" -- " .. detail) or "")) end
end

local X = "Diligent"
local cov = Cfg.activeTraits()
local traits = {}; for _, t in ipairs(cov) do traits[#traits + 1] = t end; traits[#traits + 1] = "species"
local opts = { target = X, traitOrder = cov, isGood = Cfg.isGoodValue, speciesKey = Cfg.speciesKey }

local donor = Sim.makeGoodRaw(traits, "Ended")            -- foreign species, all good
local xbad = function() return Sim.makeStartingRaw(traits, X) end -- X-pure, all bad

-- ---- unit: scoring / stage ----
do
  local xb = xbad()
  check("X-bad scores species(2)+0 traits at working=1", Combine.correctAlleles(xb, 1, opts) == 2,
    "got " .. Combine.correctAlleles(xb, 1, opts))
  check("donor scores 0 species + all good traits", Combine.correctAlleles(donor, #cov, opts) == 2 * #cov,
    "got " .. Combine.correctAlleles(donor, #cov, opts))
  check("stage of {X-bad} is 0 (species pure, no traits fixed)", Combine.stage({ xb }, opts) == 0)
  check("not done at start", not Combine.isDone({ xb, donor }, opts))
  local pick = Combine.selectPair({ xb, donor }, opts)
  check("selectPair returns a pair at stage 0", pick.princess ~= nil and pick.stage == 0 and pick.working == 1)
end

-- A hand-built perfect bee is detected as done.
do
  local perfect = Sim.makeGoodRaw(traits, X) -- X species + all good = perfect
  check("stage of a perfect bee == #traits", Combine.stage({ perfect }, opts) == #cov)
  check("isDone true for a perfect bee", Combine.isDone({ perfect }, opts))
  check("selectPair reports done", Combine.selectPair({ perfect }, opts).done == true)
end

-- ---- e2e: drive the planner through crossRaw to convergence ----
do
  local pool = { donor }
  for _ = 1, 6 do pool[#pool + 1] = xbad() end
  local F, CAP = 8, 12
  local rounds, done = 0, false
  for r = 1, 4000 do
    rounds = r
    if Combine.isDone(pool, opts) then done = true; break end
    local pick = Combine.selectPair(pool, opts)
    if pick.done then done = true; break end
    local kids = {}
    for _ = 1, F do kids[#kids + 1] = Sim.crossRaw(traits, pick.princess, pick.drone) end
    -- new pool = donor (always kept: the good-allele source) + top by working fitness
    for _, g in ipairs(pool) do kids[#kids + 1] = g end
    local w = pick.working
    table.sort(kids, function(p, q) return Combine.correctAlleles(p, w, opts) > Combine.correctAlleles(q, w, opts) end)
    local np = { donor }
    for i = 1, CAP do if kids[i] then np[#np + 1] = kids[i] end end
    pool = np
  end
  check("serial-imprint combine REACHED a perfect species-pure bee", done and Combine.isDone(pool, opts),
    "final stage " .. Combine.stage(pool, opts) .. "/" .. #cov .. " after " .. rounds .. " rounds")
  print(string.format("  (converged in %d rounds; final stage %d/%d)", rounds, Combine.stage(pool, opts), #cov))
end

print("")
if failures == 0 then print("ALL TESTS PASSED")
else print(failures .. " TEST(S) FAILED"); os.exit(1) end
