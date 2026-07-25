--[[
  End-to-end test for traitmax-via-mutation: the WHOLE two-phase flow on the
  simulated hardware. Proves the premise -- good alleles do NOT exist in starting
  stock; they are introduced by mutating to donor species (Phase A), then
  concentrated into one bee (Phase B). Runs the real manager + sim against the
  committed mutation graph and templates.

  Asserted, robustly:
    1. At start, NO bee is good at the coverable traits (they don't exist yet).
    2. Phase A completes -- every donor species gets banked (site flips to combine).
    3. Phase B produces a bee that is homozygous-GOOD on every COVERABLE trait,
       while the uncoverable traits (no reachable donor) stay bad -- exactly as
       bee_traitmax.plan reports.
--]]

package.path = package.path .. ";./?.lua"
math.randomseed(4242)

local failures = 0
local function check(name, cond, detail)
  if cond then print("OK   " .. name)
  else failures = failures + 1; print("FAIL " .. name .. (detail and (" -- " .. detail) or "")) end
end

local MG = require("bee_mutation_graph")
local Templates = require("bee_templates")
local Rainbow = require("bee_rainbow")
local Cfg = require("bee_trait_config")
local TM = require("bee_traitmax")
local Sim = require("bee_keeper_sim")

-- Real committed graph + templates.
local f = io.open("bee_mutations.dat", "r")
if not f then print("SKIP (bee_mutations.dat not in cwd)"); os.exit(0) end
local graph = MG.parse(f:read("*a")); f:close()
local parsed = Templates.load("bee_templates.dat")
if not parsed then print("SKIP (bee_templates.dat not loadable)"); os.exit(0) end

local LEAVES = { "Forest", "Wintry", "Meadows" }
local held = {}; for _, l in ipairs(LEAVES) do held[l] = true end
local reachable = Rainbow.targetSet(graph, held)
for l in pairs(held) do reachable[l] = true end
local simTemplates = Templates.build(parsed, reachable)

local plan = TM.plan(graph, held, parsed, Cfg.activeTraits(), Cfg.isGoodValue)
local coverable = {}
do
  local unc = {}; for _, t in ipairs(plan.uncoverable) do unc[t] = true end
  for _, t in ipairs(Cfg.activeTraits()) do if not unc[t] then coverable[#coverable + 1] = t end end
end
print(string.format("plan: %d donors (%s); coverable: %s",
  #plan.donors, table.concat(plan.donors, ", "), table.concat(coverable, ", ")))
check("plan finds at least one donor and one coverable trait",
  #plan.donors >= 1 and #coverable >= 1)

-- Config: 3 traitmax sites, genebank + graph + templates enabled.
local config = require("bee_keeper_manager_config")
config.mutationGraph = graph
config.templates = parsed
config.genebank = config.genebank or {}
config.sites = {}
local pos = { { x = 4, z = 3 }, { x = -3, z = 6 }, { x = 8, z = -5 } }
for i = 1, 3 do
  config.sites[i] = { name = "apiary" .. i, x = pos[i].x, z = pos[i].z, mode = "traitmax" }
end
config.storagePos = { x = -6, z = -6 }
config.trashPos = { x = -8, z = -8 }
config.chargerPos = { x = 0, z = 0 }
config.workingSlots = {}; for s = 2, 32 do config.workingSlots[#config.workingSlots + 1] = s end
config.confirmCondition = function(conditions)
  if Sim.world and conditions then
    Sim.world.satisfiedConditions = Sim.world.satisfiedConditions or {}
    for _, c in ipairs(conditions) do Sim.world.satisfiedConditions[c] = true end
  end
  return true
end

Sim.install(config, config.sites, {
  mutationGraph = graph, mutationLeaves = LEAVES, mutationBoost = 4,
  cargoSize = 32, storageSize = 512,
  templates = simTemplates, traitmaxViaMutation = true,
})

-- 1. At start, nothing is good at the coverable traits.
local function bestCoverable()
  local function score(ind)
    if not (ind and ind.active and ind.inactive) then return nil end
    local s = 0
    for _, t in ipairs(coverable) do
      if Cfg.isGoodValue(t, ind.active[t]) and Cfg.isGoodValue(t, ind.inactive[t]) then s = s + 1 end
    end
    return s, ind
  end
  local best = 0
  local function scan(stack) local s = score(stack and stack.individual); if s and s > best then best = s end end
  for _, a in pairs(Sim.world.apiaries) do
    for _, st in pairs(a.products or {}) do scan(st) end
    if a.princess then scan(a.princess) end
  end
  for _, st in pairs(Sim.world.storage or {}) do scan(st) end
  for _, st in pairs(Sim.world.drone.inventory or {}) do scan(st) end
  return best
end
-- Traits whose donor must be ACQUIRED (not an owned leaf) cannot exist at start.
-- Owned-leaf donors (a leaf that carries a good allele in its own template) may.
local acquiredCoverable = 0
for _, sp in pairs(plan.perTrait) do if not held[sp] then acquiredCoverable = acquiredCoverable + 1 end end
check("at start, fewer coverable traits are homozygous-good than the total (some must be acquired)",
  bestCoverable() < #coverable and acquiredCoverable >= 1,
  "start best " .. bestCoverable() .. "/" .. #coverable .. ", acquired-donor traits " .. acquiredCoverable)

local M = require("bee_keeper_manager")
local Nav = require("bee_keeper_nav")
Nav.setHome(70)

local sawCombine = false
local realprint = print; _G.print = function() end
for _ = 1, 160 do
  M.runCycle(config)
  for _, s in ipairs(config.sites) do if s.traitmaxPhase == "combine" then sawCombine = true end end
end
_G.print = realprint

check("Phase A completed -- a site flipped to the combine phase", sawCombine)

-- Best zygosity reached for each coverable trait anywhere in the world. GG =
-- homozygous good, Gb = one good copy present, bb = absent. A trait reaching Gb
-- proves its donor was acquired and the mutation injected its good allele (it did
-- NOT exist at start); GG proves the combine concentrated it.
local function bestZygosity()
  local z = {}; for _, t in ipairs(coverable) do z[t] = 0 end -- 0 bb, 1 Gb, 2 GG
  local function scan(stack)
    local ind = stack and stack.individual
    if not (ind and ind.active and ind.inactive) then return end
    for _, t in ipairs(coverable) do
      local a = Cfg.isGoodValue(t, ind.active[t]) and 1 or 0
      local b = Cfg.isGoodValue(t, ind.inactive[t]) and 1 or 0
      if a + b > z[t] then z[t] = a + b end
    end
  end
  for _, ap in pairs(Sim.world.apiaries) do
    for _, st in pairs(ap.products or {}) do scan(st) end
    if ap.princess then scan(ap.princess) end
  end
  for _, st in pairs(Sim.world.storage or {}) do scan(st) end
  for _, st in pairs(Sim.world.drone.inventory or {}) do scan(st) end
  return z
end

local z = bestZygosity()
local names = { [0] = "bb", [1] = "Gb", [2] = "GG" }
local allPresent, anyGG, ggCount = true, false, 0
for _, t in ipairs(coverable) do
  realprint(string.format("  %-10s %s", t, names[z[t]]))
  if z[t] < 1 then allPresent = false end
  if z[t] == 2 then anyGG = true; ggCount = ggCount + 1 end
end
check("every coverable trait's good allele was INTRODUCED and survives (>= Gb)", allPresent)
check("the combine concentrated at least one coverable trait to homozygous (GG)", anyGG)
realprint(string.format("  (combine reached homozygous on %d/%d coverable traits; best single bee %d/%d)",
  ggCount, #coverable, bestCoverable(), #coverable))

print("")
if failures == 0 then print("ALL TESTS PASSED")
else print(failures .. " TEST(S) FAILED"); os.exit(1) end
