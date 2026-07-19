--[[
  Bee Trait Target Configuration
  --------------------------------
  This is the "reduction layer" bee_breeding.lua's header docs describe:
  for every trait a project cares about, it defines what counts as "good"
  vs "bad" when converting a RAW analyzed Forestry/gendustry allele value
  (as read from bee.individual.active[trait] / bee.individual.inactive[trait])
  into the good/bad model bee_breeding.lua works with. bee_breeding.lua
  itself never needs to know any of this -- it only ever sees "good"/"bad".

  Raw value domains below were corrected against an actual analyzed bee
  dump (an extrabees.species.sticky x forestry.speciesFarmerly hybrid) --
  NOT beeManager.lua's scoring tables, which turned out to assume the
  wrong raw formats in several places. See the notes on each trait.

  species is NOT listed in M.targets -- it's handled dynamically by
  M.normalizeGenotype's targetSpecies argument, since "good" for species
  depends on which target species a given breeding project is working
  toward, not one fixed value (see bee_breeding.lua's header docs).

  CORRECTIONS MADE AFTER SEEING REAL DATA:

    - species is a NESTED TABLE, not a plain string:
        { uid = "extrabees.species.sticky", name = "Sticky",
          humidity = "Normal", temperature = "Normal" }
      beeManager.lua uses `bee.individual.active.species` directly all
      over (mutateSpeciesChance, addBySpecies, selectPair, isPureBred,
      table keys, etc.) as if it were already a plain identifier -- with
      real data, every one of those is comparing/keying on a table, which
      in Lua only matches by reference, not value. Two different bees of
      the same species will have two different (non-`==`) species tables,
      so none of that code can actually be working as intended. This
      module sidesteps it by extracting a plain field first (see
      SPECIES_KEY_FIELD below) -- but beeManager.lua's own call sites
      still have the bug; that's unchanged/left for later as requested.
      Note beeManager.lua's own `fixName(name) return name.name end`
      (used on getBeeParents results) already establishes "extract .name"
      as this codebase's convention for this exact object shape, which is
      why SPECIES_KEY_FIELD defaults to "name" rather than "uid" --
      verify that matches how your beeNames.txt/mutations.txt are keyed.

    - temperatureTolerance / humidityTolerance are enum tokens like
      "UP_1", "NONE" -- NOT the display strings ("Up 1", "None") that
      beeManager.lua's scoresTolerance table is keyed by. Target updated
      to "BOTH_5", extrapolating the shown UP_1/NONE naming pattern
      (None/Up_N/Down_N/Both_N). scoresTolerance will never match real
      values as beeManager.lua currently has it.

    - flowerProvider values look like "flowersWheat", "flowersJungle"
      (camelCase, `flowers` + capitalized type) -- NOT beeManager.lua's
      display strings ("Wheat", "Rocks", "Jungle"). Target updated to a
      BEST GUESS of "flowersRocks" by extrapolating the pattern from only
      two observed examples -- UNCONFIRMED, verify against a bee that
      actually has the Rocks flower type before relying on it.

    - territory is a plain array `{ [1]=x, [2]=y, [3]=z }`, not a
      Vec3i-stringified value -- beeManager.lua's scoresTerritory table
      (keyed by strings like "Vec3i{x=9, y=6, z=9}", one entry even has a
      mismatched bracket) can't match this shape at all. Left as "any"
      here since you called it irrelevant, so it doesn't matter for this
      module, but flagging since it's a real dead lookup in beeManager.lua.

    - effect values are namespaced strings like
      "extrabees.effect.ectoplasm" / "forestry.allele.effect.none" -- not
      beeManager.lua's display strings ("None", "Beatific", "Aggressive").
      Also left as "any" per your call, same reasoning as territory.

    - "diurnal" and "pollination" do not appear ANYWHERE in the real dump.
      The complete active/inactive key set observed is exactly: species,
      speed, fertility, nocturnal, tolerantFlyer, caveDwelling,
      temperatureTolerance, humidityTolerance, effect, flowering,
      flowerProvider, territory, lifespan -- 13 keys, matching
      beeManager.lua's own traitPriority list (minus the derived,
      non-chromosome "speciesChance") plus lifespan and species, exactly.
      Neither trait is a real chromosome on this bee. Removed both from
      M.targets/M.allTraits entirely rather than leaving them as unmet
      "equals true" requirements: since normalizeGenotype would read a
      missing key as `nil`, `nil == true` is always false, and that trait
      would be stuck at "bad" forever with no possible bee ever able to
      satisfy it -- a config-level version of exactly the "permanently
      unfixable trait" failure mode the breeding algorithm itself was
      fixed against earlier. If you want round-the-clock work, nocturnal
      alone is likely what does that (default bees already work days;
      nocturnal adds nights) -- there's no separate day-shift chromosome
      in the real data.
--]]

local M = {}

-- Which field to pull off a species table (active.species / inactive.species)
-- to use as its plain identifier. beeManager.lua's own fixName() convention
-- uses "name"; switch to "uid" if your beeNames.txt/mutations.txt are keyed
-- by the namespaced id (e.g. "extrabees.species.sticky") instead.
M.SPECIES_KEY_FIELD = "name"

local function speciesKey(rawSpeciesValue)
  if type(rawSpeciesValue) == "table" then
    return rawSpeciesValue[M.SPECIES_KEY_FIELD]
  end
  return rawSpeciesValue -- already a plain value (e.g. in a synthetic/test genotype)
end
M.speciesKey = speciesKey

-- Each entry describes what makes a RAW allele value "good" for that trait.
-- kind:
--   "equals"  -- good if value == target (numbers, strings, booleans)
--   "atLeast" -- good if value >= target (higher is better)
--   "atMost"  -- good if value <= target (lower is better)
--   "any"     -- irrelevant: every value counts as good (trait ignored)
M.targets = {
  temperatureTolerance = { kind = "equals",  target = "BOTH_5" },
  humidityTolerance     = { kind = "equals",  target = "BOTH_5" },
  nocturnal              = { kind = "equals",  target = true },
  tolerantFlyer          = { kind = "equals",  target = true },
  caveDwelling           = { kind = "equals",  target = true },
  lifespan               = { kind = "atMost",  target = 10 },   -- "Shortest"
  flowering              = { kind = "atLeast", target = 35 },   -- "Fastest" ("blinding" production)
  flowerProvider         = { kind = "equals",  target = "flowersRocks" }, -- UNCONFIRMED, see notes above
  fertility              = { kind = "atLeast", target = 4 },

  -- Explicitly irrelevant, per your call -- tracked as known traits, but
  -- any value passes. Flip `kind` to "equals"/"atLeast"/"atMost" and set a
  -- target whenever you decide you care.
  effect      = { kind = "any" },
  territory   = { kind = "any" },

  -- Not mentioned either way -- defaulted to "any" for now. Add a target
  -- (e.g. { kind = "atLeast", target = 1.7 } for fastest) if you want
  -- speed tracked too.
  speed = { kind = "any" },
}

-- Stable order for traitList construction (Lua's `pairs` gives no
-- guaranteed order, and generation-log output should read consistently).
-- Matches the real observed chromosome set exactly (species handled
-- separately -- see M.normalizeGenotype).
M.allTraits = {
  "fertility", "speed", "lifespan", "flowering", "flowerProvider",
  "temperatureTolerance", "humidityTolerance", "nocturnal",
  "tolerantFlyer", "caveDwelling", "effect", "territory",
}

-- Given a trait's target spec and a raw allele value (as it appears in
-- bee.individual.active[trait] / .inactive[trait]), return true if that
-- value counts as "good".
function M.isGoodValue(traitName, rawValue)
  local spec = M.targets[traitName]
  if not spec or spec.kind == "any" then
    return true
  elseif spec.kind == "equals" then
    return rawValue == spec.target
  elseif spec.kind == "atLeast" then
    return rawValue >= spec.target
  elseif spec.kind == "atMost" then
    return rawValue <= spec.target
  else
    error("Unknown target kind '" .. tostring(spec.kind) .. "' for trait '" .. traitName .. "'")
  end
end

-- The subset of M.allTraits that currently has a real target set (kind ~=
-- "any") -- i.e. the traits that actually matter to this project's
-- breeding goals right now. Feed this (plus "species") into bee_breeding.lua
-- as traitList.
function M.activeTraits()
  local list = {}
  for _, trait in ipairs(M.allTraits) do
    local spec = M.targets[trait]
    if spec and spec.kind ~= "any" then
      table.insert(list, trait)
    end
  end
  return list
end

-- Converts one real analyzed bee's genome from raw Forestry/gendustry
-- values into a bee_breeding.lua-style genotype, using this config's
-- targets. traitList should be M.activeTraits() (or a filtered subset of
-- it) plus "species" if the project is tracking it.
--
-- rawActive / rawInactive: the raw value tables, e.g.
--   bee.individual.active, bee.individual.inactive
-- targetSpecies: the plain identifier (matching M.SPECIES_KEY_FIELD, e.g.
--   a display name like "Sticky") this project is currently breeding
--   toward. Only used for the "species" locus; pass nil if not tracking it.
--
-- Returns a genotype table matching bee_breeding.lua's expected format:
--   { [trait] = { active = "good"|"bad", inactive = "good"|"bad" }, ... }
function M.normalizeGenotype(traitList, rawActive, rawInactive, targetSpecies)
  local genotype = {}
  for _, trait in ipairs(traitList) do
    if trait == "species" then
      genotype.species = {
        active = (speciesKey(rawActive.species) == targetSpecies) and "good" or "bad",
        inactive = (speciesKey(rawInactive.species) == targetSpecies) and "good" or "bad",
      }
    else
      genotype[trait] = {
        active = M.isGoodValue(trait, rawActive[trait]) and "good" or "bad",
        inactive = M.isGoodValue(trait, rawInactive[trait]) and "good" or "bad",
      }
    end
  end
  return genotype
end

return M
