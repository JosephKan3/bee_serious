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
    lua bee_keeper_fast_debug.lua [cycles] [mode] [targetSpecies]

  cycles         how many cycles to run (default 40)
  mode           traitmax (default), species, or mutation
  targetSpecies  only meaningful for species/mutation modes

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
local MODES = { traitmax = true, species = true, mutation = true }
if not MODES[mode] then mode = "traitmax" end
if mode == "species" then targetSpecies = targetSpecies or "Sticky"
elseif mode == "mutation" then targetSpecies = targetSpecies or "NewBee" end

local Sim = require("bee_keeper_sim")
local config = require("bee_keeper_manager_config")

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
config.workingSlots = config.workingSlots or { 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 }

Sim.install(config, config.sites, {})

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
