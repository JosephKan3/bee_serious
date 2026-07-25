--[[
  Bee Program (pure)
  ------------------
  A global PROGRAM is an ordered list of phases the robot works through across
  the WHOLE apiary array, advancing to the next phase once the current one's goal
  is met. This is the chaining the user asked for:

    traitmax  -> get the best attainable allele set (via mutation to donors)
    rainbow   -> bank a purebred of every reachable species
    perfect   -> imbue that allele set into each banked species
                 (a purebred of each species with all the good alleles)

  This module is ONLY the sequencer -- a tiny, pure state machine over the phase
  list. The manager owns the per-phase goal checks (they need live storage
  genomes) and calls M.advance when a phase completes; it reads M.current to know
  which mode every site should run this cycle.
--]]

local M = {}

-- The default program: max the alleles, bank every reachable species, then make
-- each banked species PERFECT (species-pure + the maxed allele set bred in).
-- Override via config (config.program = { phases = {...} }).
M.DEFAULT_PHASES = { "traitmax", "rainbow", "perfect" }

-- Create program state from a phase list (defaults to DEFAULT_PHASES).
function M.new(phases)
  return { phases = phases or M.DEFAULT_PHASES, index = 1 }
end

-- The phase to run now, or nil when the program is finished.
function M.current(prog)
  if not prog then return nil end
  return prog.phases[prog.index]
end

-- Whether the whole program is complete (every phase advanced past).
function M.done(prog)
  return not prog or prog.index > #prog.phases
end

-- Move to the next phase. No-op once done. Returns the new current phase (or nil).
function M.advance(prog)
  if prog and prog.index <= #prog.phases then
    prog.index = prog.index + 1
  end
  return M.current(prog)
end

-- Phases remaining including the current one (for progress reporting).
function M.remaining(prog)
  if not prog then return 0 end
  return math.max(0, #prog.phases - prog.index + 1)
end

return M
