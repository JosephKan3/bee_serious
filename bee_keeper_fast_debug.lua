--[[
  Fast Debug Driver
  -----------------
  Same simulated world as bee_keeper_local_sim_run.lua (same site layout,
  same real bee_keeper_manager.lua/bee_keeper_nav.lua decision logic) but
  with EVERY pacing hook left unset (Status.onChange/Nav.onStep stay nil)
  and no UI at all -- M.runCycle just runs at full native speed. Hundreds
  of cycles finish in well under a second, instead of minutes watching
  the animated "ui paused ..." dashboard in real time. Use this whenever
  you need to inspect logic/state across many cycles, not to WATCH
  behavior play out live (that's what bee_keeper_local_sim_run.lua's "ui"
  mode is for).

  Usage:
    lua bee_keeper_fast_debug.lua [cycles] [mode] [targetSpecies] [hard]

  cycles         how many cycles to run (default 40)
  mode           traitmax (default), species, or mutation
  targetSpecies  only meaningful for species/mutation modes
  genebank       (mutation mode) enable per-species purebred reserves
                 (config.genebank). Correct for real Forestry; the local sim
                 lacks species dominance so multi-step purification leaks --
                 use for 1-step targets / inspecting the reserve logic.
  hard           affects traitmax's general population AND a
                 species-mode site's targetSpecies population --
                 scatters good QUALITY alleles across three DIFFERENT
                 starting drone lineages instead of handing over an
                 instant-good one (see bee_keeper_sim.lua's newWorld
                 opts.hard); purebred stays reachable but now genuinely
                 takes several real generations of combining separate
                 lineages together. Mutation mode is unaffected.

  Prints one line per cycle (the same [mode] site: status log runCycle
  already returns) plus, after every cycle, a warning for any apiary
  that still has occupied product/output slots -- the thing to watch
  when chasing a "leaves without extracting" style bug. Reads
  Sim.world directly for anything deeper (cargo contents, per-slot
  analyzed state, uids, etc.) -- it's just a real Lua table, no special
  API needed.
--]]

local args = { ... }
local cycles = tonumber(args[1]) or 40
local mode = args[2] or "traitmax"
local targetSpecies = args[3]
local hardMode = false
local genebankMode = false
local MODES = { traitmax = true, species = true, mutation = true }
if not MODES[mode] then mode = "traitmax" end
for _, a in ipairs(args) do
  if a == "hard" then hardMode = true end
  if a == "genebank" then genebankMode = true end
end
if mode == "species" then targetSpecies = targetSpecies or "Sticky"
elseif mode == "mutation" then targetSpecies = targetSpecies or "Common" end

local Sim = require("bee_keeper_sim")
local MG = require("bee_mutation_graph")
local config = require("bee_keeper_manager_config")

-- Load the REAL GTNH mutation graph for mutation-mode runs, so the sim
-- breeds using the actual directional recipes (not a hand-written demo
-- table) and the manager plans the real tree toward targetSpecies. The
-- default target "Common" is a one-step mutation (Forest princess x
-- Meadows drone) reachable from the sim's seeded mutation-site stock;
-- pass a deeper target as arg 3 to exercise a multi-step tree.
local mutationGraph = nil
if mode == "mutation" then
  local f = io.open("bee_mutations.dat", "r")
  if f then
    local ok, g = pcall(MG.parse, f:read("*a"))
    f:close()
    if ok then mutationGraph = g end
  end
  if not mutationGraph then
    print("WARNING: bee_mutations.dat not loaded -- falling back to a demo recipe (target 'NewBee').")
    targetSpecies = "NewBee"
    -- Build a tiny demo graph so the MANAGER can still plan (it needs
    -- config.mutationGraph regardless of what the sim breeds), matching the
    -- sim's own NewBee demo pair (Forest princess x Meadows drone).
    mutationGraph = MG.build({ { allele1 = "Forest", allele2 = "Meadows", result = "NewBee", chance = 50 } })
    config.mutationGraph = mutationGraph
  else
    config.mutationGraph = mutationGraph
    -- Per-species genebank reserves prevent a base/intermediate species from
    -- drifting away over a multi-step tree. OPT-IN here via the "genebank" arg:
    -- the fix is correct for real Forestry (species dominance makes the
    -- re-purification of a drifted line CONVERGE), but this local sim doesn't
    -- model species dominance -- crossRaw picks the offspring's active species
    -- at random from the mother's two alleles -- so purifying a heterozygous
    -- line here LEAKS ~50% to the other parent's species and can't demonstrate
    -- convergence. Until the sim gains a dominance model, leave it off by
    -- default so the multi-step demo isn't misleadingly stalled. (1-step
    -- targets work fine with it on.)
    -- Explicit: honor the config's genebank settings only when asked, else
    -- force it off (the config file enables it by default, but the sim can't
    -- validate multi-step purification without a dominance model -- see above).
    if not genebankMode then config.genebank = nil end
    -- Auto-confirm any special-condition gate so a headless run never
    -- blocks; also mark those conditions satisfied in the sim world so the
    -- conditioned mutation can actually fire (see Sim world below).
    config.confirmCondition = function(conditions)
      if Sim.world and conditions then
        Sim.world.satisfiedConditions = Sim.world.satisfiedConditions or {}
        for _, c in ipairs(conditions) do Sim.world.satisfiedConditions[c] = true end
      end
      return true
    end
  end
end

-- The base leaf bees the target's whole tree needs (computed from the real
-- graph, empty starting stock) -- handed to the sim so it seeds exactly
-- those, letting a multi-step target breed to completion headlessly.
local mutationLeaves = nil
if mutationGraph then
  local plan = MG.planBreedingTree(mutationGraph, {}, targetSpecies)
  if plan.reachable then
    mutationLeaves = plan.missingLeaves
    if #mutationLeaves > 0 then
      print("Target '" .. targetSpecies .. "' needs base leaf bees: " .. table.concat(mutationLeaves, ", "))
    end
  else
    print("WARNING: target '" .. targetSpecies .. "' is unreachable in the mutation graph.")
  end
end

local SITE_COUNT = 3
local sitePositions = { { x = 4, z = 3 }, { x = -3, z = 6 }, { x = 8, z = -5 } }
config.sites = {}
for i = 1, SITE_COUNT do
  table.insert(config.sites, {
    name = "apiary" .. i, x = sitePositions[i].x, z = sitePositions[i].z,
    mode = mode, targetSpecies = targetSpecies,
  })
end
config.storagePos = config.storagePos or { x = -6, z = -6 }
config.trashPos = config.trashPos or { x = -8, z = -8 }
config.chargerPos = config.chargerPos or { x = 0, z = 0 }
-- Genebank runs model a bigger robot (32 slots) so banks for several species fit
-- in cargo at once; other modes keep the smaller default.
if not config.workingSlots then
  config.workingSlots = {}
  for s = 2, (genebankMode and 32 or 16) do table.insert(config.workingSlots, s) end
end

-- Genebank runs model mutation-boosting frames (see sim mutationBoost) so a
-- purebred x purebred cross reliably mutates instead of burning many base
-- princesses at the raw ~15% rate -- what real breeders do -- and give storage
-- room for the larger pristine base reserve.
Sim.install(config, config.sites, {
  hard = hardMode,
  mutationGraph = mutationGraph,
  mutationLeaves = mutationLeaves,
  mutationBoost = genebankMode and 6 or 1,
  cargoSize = genebankMode and 32 or nil,        -- a 32-slot robot
  storageSize = genebankMode and 108 or nil,     -- an etfuturum diamond barrel
})

local M = require("bee_keeper_manager")
local Nav = require("bee_keeper_nav")
Nav.setHome(70)
-- Status.onChange/Nav.onStep are left nil (never assigned) -- no sleep,
-- no redraw, nothing to slow this down.

for cycle = 1, cycles do
  local log = M.runCycle(config)
  print(string.format("== cycle %d ==", cycle))
  for _, line in ipairs(log) do print("  " .. line) end
  for key, a in pairs(Sim.world.apiaries) do
    local leftover = a.products and next(a.products)
    if leftover then
      local n = 0
      for _ in pairs(a.products) do n = n + 1 end
      print(string.format("  [!] apiary@%s still has %d output slot(s) occupied after this cycle", key, n))
    end
  end
end

print(string.format("\nDone -- %d cycles. Sim.world is the live state table if you need to inspect further.", cycles))
