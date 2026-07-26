--[[
  Bee Trace -- shared state-trace format (pure, no hardware)
  ----------------------------------------------------------
  A "trace" is an append-only log of per-STEP state snapshots. The REAL runner
  (bee_keeper_manager_run trace <file>) writes one snapshot per task boundary as
  Minecraft actually executes; the SIMULATOR reads that file back to:
    1. IMPORT INHERITANCE -- replace its own random mating outcomes with the exact
       offspring genomes Minecraft produced, so the sim tracks the real run; and
    2. VALIDATE -- diff every other piece of state (positions, which bees moved
       where, counts) against the trace and ALERT on any divergence, since a
       non-inheritance difference means the sim's LOGIC disagrees with Minecraft.

  Same file is produced and consumed on both sides, so the format has to load
  under BOTH OpenOS and plain Lua -- it's newline-delimited Lua table literals,
  parsed with load() in an empty environment (no os/io/etc. reachable).

  A snapshot:
    {
      seq = <int>,                 -- monotonic step index
      cycle = <int>, step = "...", -- run cycle + Status step text
      pos = { x=, z= }, sel = <slot|false>,
      cargo = { [slot] = <beeRec> },              -- robot cargo (genomes)
      apiary = { key="x:z", queen=<beeRec>, drone=<beeRec>, out={ [slot]=<beeRec> } },
        -- only the apiary the robot is currently ABOVE (what it can actually see);
        -- nil when not over an apiary
      births = { <beeRec>, ... },  -- offspring genomes produced by a mating THIS
        -- step (the inheritance RNG to import); empty/absent when no mating fired
    }

  beeRec = {
    kind = "princess"|"drone"|"queen", analyzed = <bool>, size = <int>,
    active   = { species="Forest", fertility=2, ... },   -- flat: trait -> value
    inactive = { species="Meadows", fertility=2, ... },  -- species reduced to its NAME
  }
--]]

local M = {}

-- ---- pure serializer (tables of number|string|boolean|table) --------------
local function serialize(v, out)
  local t = type(v)
  if t == "number" then
    out[#out + 1] = (v == math.floor(v)) and string.format("%d", v) or tostring(v)
  elseif t == "string" then
    out[#out + 1] = string.format("%q", v)
  elseif t == "boolean" then
    out[#out + 1] = tostring(v)
  elseif t == "table" then
    out[#out + 1] = "{"
    -- array part first (contiguous 1..n), then keyed part (sorted for stability)
    local n = 0
    while v[n + 1] ~= nil do n = n + 1 end
    for i = 1, n do serialize(v[i], out); out[#out + 1] = "," end
    local keys = {}
    for k in pairs(v) do
      if not (type(k) == "number" and k >= 1 and k <= n and k == math.floor(k)) then
        keys[#keys + 1] = k
      end
    end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    for _, k in ipairs(keys) do
      if type(k) == "string" and k:match("^[%a_][%w_]*$") then
        out[#out + 1] = k .. "="
      else
        out[#out + 1] = "["; serialize(k, out); out[#out + 1] = "]="
      end
      serialize(v[k], out); out[#out + 1] = ","
    end
    out[#out + 1] = "}"
  else
    out[#out + 1] = "nil"
  end
  return out
end

function M.serialize(v)
  return table.concat(serialize(v, {}))
end

-- Parse one serialized record back into a table, sandboxed (no globals reachable).
function M.parse(line)
  if not line or line == "" then return nil end
  local chunk = "return " .. line
  local f, err
  if _G.load then
    f, err = _G.load(chunk, "trace", "t", {})
  else
    f, err = loadstring(chunk) -- Lua 5.1 fallback (empty env not enforced; fine offline)
  end
  if not f then return nil, err end
  local ok, val = pcall(f)
  if not ok then return nil, val end
  return val
end

-- ---- bee genome <-> beeRec -------------------------------------------------

-- Flatten one haploid allele set (individual.active or .inactive) to trait->value,
-- reducing the species table to its plain name so records compare by ==.
local function flattenAlleles(alleles)
  local flat = {}
  for trait, val in pairs(alleles) do
    if trait == "species" and type(val) == "table" then
      flat.species = val.name
    else
      flat[trait] = val
    end
  end
  return flat
end
M.flattenAlleles = flattenAlleles

-- Build a beeRec from a raw item stack (as read via inventory_controller /
-- getStackInInternalSlot). Returns nil for non-bee / unanalyzed-without-genome.
function M.beeRecord(stack)
  if not stack or not stack.individual then return nil end
  local ind = stack.individual
  local kind = "?"
  local nm = (stack.name or ""):lower()
  if nm:find("queen") then kind = "queen"
  elseif nm:find("princess") then kind = "princess"
  elseif nm:find("drone") then kind = "drone" end
  local rec = { kind = kind, analyzed = ind.isAnalyzed and true or false, size = stack.size or 1 }
  if ind.active and ind.inactive then
    rec.active = flattenAlleles(ind.active)
    rec.inactive = flattenAlleles(ind.inactive)
  end
  return rec
end

-- Stable string signature of a beeRec's GENOME (kind + both allele sets),
-- ignoring size -- used to compare two bees for "same individual genome".
function M.genomeSig(rec)
  if not rec then return "-" end
  if not rec.active then return rec.kind .. ":unanalyzed" end
  local parts = { rec.kind }
  local traits = {}
  for k in pairs(rec.active) do traits[#traits + 1] = k end
  table.sort(traits)
  for _, t in ipairs(traits) do
    parts[#parts + 1] = t .. "=" .. tostring(rec.active[t]) .. "/" .. tostring(rec.inactive[t])
  end
  return table.concat(parts, ",")
end

-- ---- writer ----------------------------------------------------------------
-- Returns a writer { step=function(snapshot), close=function() }. `open` is an
-- io.open-style function (passed in so this module never touches io directly and
-- stays pure/testable); path is the trace file.
function M.writer(openFn, path)
  local fh = openFn(path, "w")
  local seq = 0
  return {
    step = function(snapshot)
      if not fh then return end
      seq = seq + 1
      snapshot.seq = seq
      fh:write(M.serialize(snapshot) .. "\n")
      fh:flush()
    end,
    close = function() if fh then fh:close() end end,
  }
end

-- ---- reader ----------------------------------------------------------------
-- Reads a whole trace file into an array of snapshots (in order).
function M.read(openFn, path)
  local fh = openFn(path, "r")
  if not fh then return nil, "not_found:" .. tostring(path) end
  local snaps = {}
  for line in fh:lines() do
    if line ~= "" then
      local s = M.parse(line)
      if s then snaps[#snaps + 1] = s end
    end
  end
  fh:close()
  return snaps
end

return M
