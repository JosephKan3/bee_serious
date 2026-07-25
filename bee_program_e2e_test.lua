--[[
  End-to-end test for GLOBAL PROGRAM PHASES: a program sequences traitmax ->
  rainbow across the whole apiary array, advancing when a phase's goal is met.
  Drives the real manager + sim; proves:
    1. The program starts in traitmax and stays there while no max bee exists.
    2. Every site runs the active phase's mode.
    3. Once a bee homozygous-good on all COVERABLE traits exists in storage
       (traitmax's goal), the program ADVANCES to rainbow and sites switch mode.
--]]

package.path = package.path .. ";./?.lua"
math.randomseed(77)

local failures = 0
local function check(name, cond, detail)
  if cond then print("OK   " .. name)
  else failures = failures + 1; print("FAIL " .. name .. (detail and (" -- " .. detail) or "")) end
end

local MG = require("bee_mutation_graph")
local Templates = require("bee_templates")
local Rainbow = require("bee_rainbow")
local Cfg = require("bee_trait_config")
local Program = require("bee_program")
local Sim = require("bee_keeper_sim")

local f = io.open("bee_mutations.dat", "r")
if not f then print("SKIP (bee_mutations.dat not in cwd)"); os.exit(0) end
local graph = MG.parse(f:read("*a")); f:close()
local parsed = Templates.load("bee_templates.dat")
if not parsed then print("SKIP (bee_templates.dat not loadable)"); os.exit(0) end

local LEAVES = { "Forest", "Wintry", "Meadows" }
local held = {}; for _, l in ipairs(LEAVES) do held[l] = true end
local reachable = Rainbow.targetSet(graph, held); for l in pairs(held) do reachable[l] = true end
local simTemplates = Templates.build(parsed, reachable)

local config = require("bee_keeper_manager_config")
config.mutationGraph = graph
config.templates = parsed
config.genebank = config.genebank or {}
config.program = Program.new({ "traitmax", "rainbow" })
config.sites = {}
local pos = { { x = 4, z = 3 }, { x = -3, z = 6 }, { x = 8, z = -5 } }
for i = 1, 3 do config.sites[i] = { name = "apiary" .. i, x = pos[i].x, z = pos[i].z, mode = "traitmax" } end
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
  cargoSize = 32, storageSize = 512, templates = simTemplates, traitmaxViaMutation = true,
})

local M = require("bee_keeper_manager")
local Nav = require("bee_keeper_nav")
Nav.setHome(70)

-- Run a few cycles: no max bee yet, so the program stays in traitmax.
local realprint = print; _G.print = function() end
for _ = 1, 5 do M.runCycle(config) end
_G.print = realprint

check("program starts in the traitmax phase", Program.current(config.program) == "traitmax")
check("every site runs the traitmax phase mode",
  config.sites[1].mode == "traitmax" and config.sites[3].mode == "traitmax")

-- Inject a bee that IS homozygous-good on every coverable trait (the traitmax
-- goal), straight into storage -- so the next cycle's program evaluation sees it.
local traits = Cfg.activeTraits(); traits[#traits + 1] = "species"
local maxBee = Sim.makeGoodRaw(traits, "Forest")
local free = 1
while Sim.world.storage[free] ~= nil do free = free + 1 end
Sim.world.storage[free] = Sim.toStack(maxBee, "princess", true)

_G.print = function() end
M.runCycle(config)
_G.print = realprint

check("program ADVANCED to rainbow once the max bee exists in storage",
  Program.current(config.program) == "rainbow", "phase=" .. tostring(Program.current(config.program)))
check("sites switched to the rainbow phase mode",
  config.sites[1].mode == "rainbow" and config.sites[2].mode == "rainbow")

print("")
if failures == 0 then print("ALL TESTS PASSED")
else print(failures .. " TEST(S) FAILED"); os.exit(1) end
