--[[ Unit tests for bee_trace.lua -- serialize/parse round-trip + bee records. ]]
local T = require("bee_trace")

local failures = 0
local function check(name, cond, detail)
  if cond then print("OK   " .. name)
  else failures = failures + 1; print("FAIL " .. name .. (detail and (" -- " .. detail) or "")) end
end

-- Round-trip a nested snapshot-like table.
do
  local snap = {
    seq = 3, cycle = 2, step = "Harvesting apiary1", pos = { x = 2, z = -2 }, sel = 5,
    cargo = { [5] = { kind = "drone", analyzed = true, size = 64,
      active = { species = "Forest", fertility = 2 }, inactive = { species = "Forest", fertility = 2 } } },
    births = { { kind = "princess", analyzed = false, size = 1,
      active = { species = "Common", fertility = 2 }, inactive = { species = "Forest", fertility = 2 } } },
  }
  local s = T.serialize(snap)
  local back = T.parse(s)
  check("round-trip seq/cycle/step", back.seq == 3 and back.cycle == 2 and back.step == "Harvesting apiary1")
  check("round-trip pos", back.pos.x == 2 and back.pos.z == -2)
  check("round-trip nested cargo genome",
    back.cargo[5].active.species == "Forest" and back.cargo[5].size == 64 and back.cargo[5].analyzed == true)
  check("round-trip births array", #back.births == 1 and back.births[1].active.species == "Common")
end

-- Special characters / booleans survive.
do
  local s = T.parse(T.serialize({ step = 'a "quote" and \\ slash', flag = false, n = -3 }))
  check("round-trip quotes/backslash", s.step == 'a "quote" and \\ slash')
  check("round-trip boolean false", s.flag == false)
  check("round-trip negative int", s.n == -3)
end

-- beeRecord from a stack + genomeSig.
do
  local stack = { name = "Forestry:beePrincessGE", size = 1, individual = {
    isAnalyzed = true,
    active = { species = { name = "Common" }, fertility = 3 },
    inactive = { species = { name = "Forest" }, fertility = 2 } } }
  local rec = T.beeRecord(stack)
  check("beeRecord kind/analyzed", rec.kind == "princess" and rec.analyzed == true)
  check("beeRecord species reduced to name", rec.active.species == "Common" and rec.inactive.species == "Forest")
  local sig = T.genomeSig(rec)
  check("genomeSig stable + includes both alleles",
    sig == T.genomeSig(rec) and sig:find("species=Common/Forest") ~= nil, sig)
  -- different genome -> different sig
  local rec2 = T.beeRecord({ name = "Forestry:beeDroneGE", size = 1, individual = {
    isAnalyzed = true, active = { species = { name = "Common" }, fertility = 3 },
    inactive = { species = { name = "Common" }, fertility = 3 } } })
  check("genomeSig differs for different genome", T.genomeSig(rec) ~= T.genomeSig(rec2))
end

-- writer/reader over an in-memory fake file (no io).
do
  local buf = {}
  local fakeFile = {
    write = function(self, s) buf[#buf + 1] = s; return self end,
    flush = function() end, close = function() end,
    lines = function() local i = 0; local all = table.concat(buf); local ls = {}
      for l in all:gmatch("[^\n]+") do ls[#ls + 1] = l end
      return function() i = i + 1; return ls[i] end end,
  }
  local openFn = function() return fakeFile end
  local w = T.writer(openFn, "x")
  w.step({ cycle = 1, step = "a", pos = { x = 0, z = 0 } })
  w.step({ cycle = 1, step = "b", pos = { x = 1, z = 0 } })
  local snaps = T.read(openFn, "x")
  check("writer assigns monotonic seq", snaps[1].seq == 1 and snaps[2].seq == 2)
  check("reader returns all steps in order", #snaps == 2 and snaps[2].step == "b")
end

print("")
if failures == 0 then print("ALL TESTS PASSED") else print(failures .. " TEST(S) FAILED"); os.exit(1) end
