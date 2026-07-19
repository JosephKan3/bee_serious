
c = require("component")
sides = require("sides")
ser = require("serialization")
comp = require("computer")

function memWait()
	os.sleep(0)
	while comp.freeMemory() < 1000 do
		print ("Sleeping for 1 second / memory = " .. comp.freeMemory())
		os.sleep(1)
	end
end

function loadFile(fileName)
  local f = io.open(fileName, "r")
  if f ~= nil then
    local data = f:read("*all")
    f:close()
	-- print (data)
	local cfg = ser.unserialize(data)
	return (cfg)
  end
end

function saveFile(fileName, data)
  local f = io.open(fileName, "w")
  f:write(ser.serialize(data))
  f:close()
end

function shuffle(tbl)
  local size = #tbl
  for i = size, 1, -1 do
    local rand = math.random(size)
    tbl[i], tbl[rand] = tbl[rand], tbl[i]
  end
  return tbl
end

mutations = loadFile("mutations.txt")
beeNames = loadFile("beeNames.txt")

bd = c.bee_housing
getBeeParents = bd.getBeeParents

local traitPriority = {
  "speciesChance", 
  "speed", 
  "fertility", 
  "nocturnal", 
  "tolerantFlyer", 
  "caveDwelling", 
  "temperatureTolerance", 
  "humidityTolerance", 
  "effect", 
  "flowering", 
  "flowerProvider", 
  "territory"
}

function setPriorities(priority)
  local species = nil
  local priorityNum = 1
  for traitNum, trait in ipairs(priority) do
    local found = false
    for traitPriorityNum = 1, #traitPriority do
      if trait == traitPriority[traitPriorityNum] then
        found = true
        if priorityNum ~= traitPriorityNum then
          table.remove(traitPriority, traitPriorityNum)
          table.insert(traitPriority, priorityNum, trait)
        end
        priorityNum = priorityNum + 1
        break
      end
    end
    if not found then
      species = trait
    end
  end
  return species
end

-- percent chance of 2 species turning into a target species
function mutateSpeciesChance(mutations, species1, species2, targetSpecies)
  local chance = {}
  if species1 == species2 then
    chance[species1] = 100
  else
    chance[species1] = 50
    chance[species2] = 50
  end
  if mutations[species1] ~= nil then
    for species, mutates in pairs(mutations[species1].mutateTo) do
      local mutateChance = mutates[species2]
      if mutateChance ~= nil then
        chance[species] = mutateChance
        chance[species1] = chance[species1] - mutateChance / 2
        chance[species2] = chance[species2] - mutateChance / 2
      end
    end
  end
  return chance[targetSpecies] or 0.0
end

-- percent chance of 2 bees turning into target species
function mutateBeeChance(mutations, princess, drone, targetSpecies)
  if princess.individual.isAnalyzed then
    if drone.individual.isAnalyzed then
      return (mutateSpeciesChance(mutations, princess.individual.active.species, drone.individual.active.species, targetSpecies) / 4
             +mutateSpeciesChance(mutations, princess.individual.inactive.species, drone.individual.active.species, targetSpecies) / 4
             +mutateSpeciesChance(mutations, princess.individual.active.species, drone.individual.inactive.species, targetSpecies) / 4
             +mutateSpeciesChance(mutations, princess.individual.inactive.species, drone.individual.inactive.species, targetSpecies) / 4)
    end
  elseif drone.individual.isAnalyzed then
  else
    return mutateSpeciesChance(mutations, princess.individual.displayName, drone.individual.displayName, targetSpecies)
  end
end

function buildScoring()
  function makeNumberScorer(trait, default)
    local function scorer(bee)
      if bee.individual.isAnalyzed then
        return (bee.individual.active[trait] + bee.individual.inactive[trait]) / 2
      else
        return default
      end
    end
    return scorer
  end

  function makeBooleanScorer(trait)
    local function scorer(bee)
      if bee.individual.isAnalyzed then
        return ((bee.individual.active[trait] and 1 or 0) + (bee.individual.inactive[trait] and 1 or 0)) / 2
      else
        return 0
      end
    end
    return scorer
  end

  function makeTableScorer(trait, default, lookup)
    local function scorer(bee)
      if bee.individual.isAnalyzed then
        return ((lookup[bee.individual.active[trait]] or default) + (lookup[bee.individual.inactive[trait]] or default)) / 2
      else
        return default
      end
    end
    return scorer
  end
  
  local scoresTerritory = {
	["Vec3i{x=9, y=6, z=9}"]    = 0,
	["Vec3i(x=11, y=8, z=11}"]  = 1,
	["Vec3i{x=13, y=12, z=13}"] = 2,
	["Vec3i{x=15, y=13, z=15}"] = 3
  }

  local scoresTolerance = {
    ["None"]   = 0,
    ["Up 1"]   = 1,
    ["Up 2"]   = 2,
    ["Up 3"]   = 3,
    ["Up 4"]   = 4,
    ["Up 5"]   = 5,
    ["Down 1"] = 1,
    ["Down 2"] = 2,
    ["Down 3"] = 3,
    ["Down 4"] = 4,
    ["Down 5"] = 5,
    ["Both 1"] = 2,
    ["Both 2"] = 4,
    ["Both 3"] = 6,
    ["Both 4"] = 8,
    ["Both 5"] = 10
  }

  local scoresFlowerProvider = {
    ["None"] = 5,
    ["Rocks"] = 4,
    ["Flowers"] = 3,
    ["Mushroom"] = 2,
    ["Cacti"] = 1,
    ["Exotic Flowers"] = 0,
    ["Jungle"] = 0
  }
  
  local scoresEffect = {
    ["None"] = 5,
	["Beatific"] = 10,
	["Aggressive"] = 0 
  }

  return {
    ["fertility"] = makeNumberScorer("fertility", 1),
    ["flowering"] = makeNumberScorer("flowering", 1),
    ["speed"] = makeNumberScorer("speed", 1),
    ["lifespan"] = makeNumberScorer("lifespan", 1),
    ["nocturnal"] = makeBooleanScorer("nocturnal"),
    ["tolerantFlyer"] = makeBooleanScorer("tolerantFlyer"),
    ["caveDwelling"] = makeBooleanScorer("caveDwelling"),
    ["effect"] = makeTableScorer("effect", 0, scoresEffect),
    ["temperatureTolerance"] = makeTableScorer("temperatureTolerance", 0, scoresTolerance),
    ["humidityTolerance"] = makeTableScorer("humidityTolerance", 0, scoresTolerance),
    ["flowerProvider"] = makeTableScorer("flowerProvider", 0, scoresFlowerProvider),
    ["territory"] = makeTableScorer("territory", 0, scoresTerritory)
  }
end

function compareBees(scorers, a, b)
  for _, trait in ipairs(traitPriority) do
    local scorer = scorers[trait]
    if scorer ~= nil then
      local aScore = scorer(a)
      local bScore = scorer(b)
      if aScore ~= bScore then
        return aScore > bScore
      end
    end
  end
  return a.slot < b.slot
end

function compareMates(a, b)
  for i, trait in ipairs(traitPriority) do
    if a[trait] ~= b[trait] then
      return a[trait] > b[trait]
    end
  end
  return true
end

do
	local traitPriority = {
	  "speed", 
	  "fertility", 
	  "nocturnal", 
	  "tolerantFlyer", 
	  "caveDwelling", 
	  "temperatureTolerance", 
	  "humidityTolerance"
	}

	function betterTraits(scorers, a, b)
	  local traits = {}
	  for _, trait in ipairs(traitPriority) do
		local scorer = scorers[trait]
		if scorer ~= nil then
		  local aScore = scorer(a)
		  local bScore = scorer(b)
		  if bScore > aScore then
			table.insert(traits, trait)
		  end
		end
	  end
	  return traits
	end
end

-- cataloging functions ---------------

function addBySpecies(beesBySpecies, bee)
  if bee.individual.isAnalyzed then
    if beesBySpecies[bee.individual.active.species] == nil then
      beesBySpecies[bee.individual.active.species] = {bee.slot}
    else
      table.insert(beesBySpecies[bee.individual.active.species], bee.slot)
    end
    if bee.individual.inactive.species ~= bee.individual.active.species then
      if beesBySpecies[bee.individual.inactive.species] == nil then
        beesBySpecies[bee.individual.inactive.species] = {bee.slot}
      else
        table.insert(beesBySpecies[bee.individual.inactive.species], bee.slot)
      end
    end
  else
    if beesBySpecies[bee.individual.displayName] == nil then
      beesBySpecies[bee.individual.displayName] = {bee.slot}
    else
      table.insert(beesBySpecies[bee.individual.displayName], bee.slot)
    end
  end
end

do
	local cache = {}
	local cacheMeta = {}
	local hits = 0
	local misses = 0
	setmetatable(cache, cacheMeta)
	cacheMeta.__mode = "v"
	getBee = function (config, slot, forced)
		if slot == nil then return nil end
		if ((hits + misses) % 500 == 0) then
			print ("cache: hits = " .. hits .. ", misses = " .. misses)
		end
		if (not forced) and (cache[slot] ~= nil) then 
			hits = hits + 1
			return cache[slot] 
		end
		misses = misses + 1
		local tr, side = next(config.storage)
		local tr1 = getTransposer(config, tr)
		local bee = tr1.getStackInSlot(sides[side], slot)
		if (bee ~= nil) then
			if (bee.individual ~= nil) then
				bee = { name=bee.name, size=bee.size, slot=slot, label=bee.label,
						individual= { active=bee.individual.active, inactive=bee.individual.inactive,
										isAnalyzed=bee.individual.isAnalyzed, displayName=bee.individual.displayName }
						}
			end
			cache[slot] = bee
			return bee
		else
			return nil
		end
	end
	invalidate = function (slot)
		cache[slot] = nil
	end
	invalidateAll = function ()
		cache = {}
	end
end

function clearMachines (config)

	if (config.imprinter ~= nil ) then
		local tr1 = getTransposer(config, config.imprinter.transposer)
		local iside = config.storage[config.imprinter.transposer]
		local tside = config.imprinter.side

		if (tr1.getStackInSlot(sides[tside], 4) ~= nil) then
			print ("Clearing imprinter")
			tr1.transferItem(sides[tside], sides[iside], 64, 4)
		end
	end
		
	if (config.mutator ~= nil ) then
		local tr1 = getTransposer(config, config.mutator.transposer)
		local iside = config.storage[config.mutator.transposer]
		local tside = config.mutator.side

		if (tr1.getStackInSlot(sides[tside], 3) ~= nil) then
			print ("Clearing mutator")
			tr1.transferItem(sides[tside], sides[iside], 64, 3)
		end
	end
		
end

function startCatalog (config, scorers) 
	local catalog = {}
	
	catalog.princesses = {}
	catalog.princessesBySpecies = {}
	catalog.drones = {}
	catalog.dronesBySpecies = {}
	catalog.queens = {}
	
	catalog.bees = {}

	catalog.referenceDronesBySpecies = {}
	catalog.referencePrincessesBySpecies = {}
	catalog.referencePairBySpecies = {}

	catalog.referenceBeeCount = 0
	catalog.referencePrincessCount = 0
	catalog.referenceDroneCount = 0
	
	catalog.scorers = scorers
	catalog.config = config 
	
	return catalog
end

function addCatalog (catalog, bee)
	local referenceBySpecies = nil
	local isDrone = nil

	if bee.name == "forestry:bee_drone_ge" then -- drones
		isDrone = true
		referenceBySpecies = catalog.referenceDronesBySpecies
	elseif bee.name == "forestry:bee_princess_ge" then -- princess
		isDrone = false
		referenceBySpecies = catalog.referencePrincessesBySpecies
	else
		isDrone = nil
	end
	if referenceBySpecies ~= nil and bee.individual.isAnalyzed and bee.individual.active.species == bee.individual.inactive.species then
		local species = bee.individual.active.species
		if referenceBySpecies[species] == nil or
			compareBees(catalog.scorers, bee, getBee(catalog.config,referenceBySpecies[species])) then
			if referenceBySpecies[species] == nil then
				catalog.referenceBeeCount = catalog.referenceBeeCount + 1
				if isDrone == true then
					catalog.referenceDroneCount = catalog.referenceDroneCount + 1
				elseif isDrone == false then
					catalog.referencePrincessCount = catalog.referencePrincessCount + 1
				end
			end
			referenceBySpecies[species] = bee.slot
			if catalog.referencePrincessesBySpecies[species] ~= nil and catalog.referenceDronesBySpecies[species] ~= nil then
				catalog.referencePairBySpecies[species] = true
			end
		end
	end
	table.insert(catalog.bees, bee.slot)
	memWait()
end

function finishCatalog (catalog)
	local tr, side = next(catalog.config.storage)
	local tr1 = getTransposer(catalog.config, tr)

	local surplus = {}

	print (string.format("found %d reference bees, %d princesses, %d drones", catalog.referenceBeeCount, catalog.referencePrincessCount, catalog.referenceDroneCount))

	local bees = catalog.bees
	
	while #bees > 0 do
		memWait()
		-- if (#bees % 100 == 0) then print ("Remaining: " .. #bees ) end
		local slot = table.remove(bees)
		local bee = getBee(catalog.config, slot)
		-- remove analyzed drones where both the active and inactive species have
		--   a both reference princess and drone
		if (bee ~= nil) then
			local skip  = false
			if (
			  bee.name == "forestry:bee_drone_ge" and
			  bee.individual.isAnalyzed and (
				catalog.referencePrincessesBySpecies[bee.individual.active.species] ~= nil and
				catalog.referenceDronesBySpecies[bee.individual.active.species] ~= nil and
				catalog.referencePrincessesBySpecies[bee.individual.inactive.species] ~= nil and
				catalog.referenceDronesBySpecies[bee.individual.inactive.species] ~= nil and
				catalog.referenceDronesBySpecies[bee.individual.active.species] ~= slot
			  )
			) then
				local activeDroneTraits = betterTraits(catalog.scorers, getBee(catalog.config, catalog.referenceDronesBySpecies[bee.individual.active.species]), bee)
				local inactiveDroneTraits = betterTraits(catalog.scorers, getBee(catalog.config, catalog.referenceDronesBySpecies[bee.individual.inactive.species]), bee)
				if #activeDroneTraits == 0 and #inactiveDroneTraits == 0 then
					skip = true
					table.insert(surplus, slot)
				end
			end
			
			if not skip then 
				if (bee.slot == catalog.referencePrincessesBySpecies[bee.individual.active.species]) then
					-- reference princess, skip
				elseif (bee.slot == catalog.referenceDronesBySpecies[bee.individual.active.species] and bee.size == 1) then
					-- reference drone, skip
				elseif bee.name == "forestry:bee_drone_ge" then -- drones
					table.insert(catalog.drones, slot)
					addBySpecies(catalog.dronesBySpecies, bee)
				elseif bee.name == "forestry:bee_princess_ge" then -- princess
					table.insert(catalog.princesses, slot)
					addBySpecies(catalog.princessesBySpecies, bee)
				elseif bee.name == "forestry:bee_queen_ge" then -- queens
					table.insert(catalog.queens, slot)
				else 
					print ("Panic! Weird thing found: " .. bee.name)
				end
			end
			
		end
	end

	local keep = {}
	for species, drones in pairs(catalog.dronesBySpecies) do
		local droneBees = getBeeMap(catalog.config, drones)
		local cmp = function (a,b) return compareBees(catalog.scorers, droneBees[a], droneBees[b]) end
		table.sort ( drones, cmp )
		for n = 1, math.min (10, #drones) do
			keep[drones[n]] = true
		end
	end
	
	local dropped = {}
	for species, drones in pairs(catalog.dronesBySpecies) do
		for n = #drones, 1, -1 do
			if not keep[drones[n]] then 
				rem = table.remove (drones, n)
				if nil == dropped[rem] then 
					table.insert(surplus, rem)
					dropped[rem] = true
				end
			end
		end
	end
	
	local dropcount = 0
	
	for n = #catalog.drones, 1, -1 do
		if dropped[catalog.drones[n]] then 
			table.remove(catalog.drones, n) 
			dropcount = dropcount + 1
		end
	end
	
	print (dropcount .. " drones marked as surplus")
	
	catalog.princesses = getBees(catalog.config, catalog.princesses)
	catalog.drones = getBees(catalog.config, catalog.drones)
	
	print (string.format("found %d queens, %d princesses, %d drones, %d surplus",
		#catalog.queens, #catalog.princesses, #catalog.drones, #surplus))
	return surplus
end

function getTransposer(config, n) 
	return c.proxy(config.transposers[n])
end

booleanMap = { [false] = "False", [true] = "True" }

function territory_fun (t)
	print (t.x, t.y, t.z)
	local k,v
	for k,v in pairs(t) do print (">>", k, v, "<<") end
	if (t.x == 9 and t.y == 6 and t.z == 9) then return "Average" 
	elseif (t[0] == 11 and t[1] == 8 and t[2] == 11) then return "Large"
	elseif (t[0] == 13 and t[1] == 12 and t[2] == 13) then return "Larger"
	elseif (t[0] == 15 and t[1] == 13 and t[2] == 15) then return "Largest"
	else return tostring(t)
	end
end

do

	translations = {
		["territory"] = { n="Territory", v = {
			["Vec3i{x=9, y=6, z=9}"]    = "Average",
			["Vec3i(x=11, y=8, z=11}"]  = "Large",
			["Vec3i{x=13, y=12, z=13}"] = "Larger",
			["Vec3i{x=15, y=13, z=15}"] = "Largest"
		} },
		["humidityTolerance"] = { n="Humidity tolerance" },
		["flowering"] = { n="Flowering", v = {
			[5] = "Slowest",
			[10] = "Slower",
			[15] = "Slow",
			[20] = "Average",
			[25] = "Fast",
			[30] = "Faster",
			[35] = "Fastest" } },
		["neverSleeps"] = { n="Never Sleeps", v = booleanMap },
		["flowerProvider"] = { n="Flowers" },
		["toleratesRain"] = { n="Tolerates Rain", v = booleanMap },
		["lifespan"] = { n="Lifespan", v = { 
			[10] = "Shortest", 
			[20] = "Shorter", 
			[30] = "Short",
			[35] = "Shortened",
			[40] = "Normal",
			[45] = "Elongated", 
			[50] = "Long",
			[60] = "Longer",
			[70] = "Longest" } },
		["caveDwelling"] = { n="Cave dwelling", v = booleanMap},
		["fertility"] = { n="Fertility", v= { [1] = "1", [2] = "2", [3] = "3", [4] = "4" } },
		["speed"] = { 
			n = "Speed", 
			f = function (x) return string.format("%.1f", x) end,
			v = { 
				["0.3"] = "Slowest",
				["0.6"] = "Slower",
				["0.8"] = "Slow",
				["1.0"] = "Normal",
				["1.2"] = "Fast",
				["1.4"] = "Faster",
				["1.7"] = "Fastest" } },
		["effect"] = { n="Effect", v = {} },
		["species"] = { n="Species" }, 
		["temperatureTolerance"] = { n="Temperature tolerance" }
	}

	function traits_wanted(seen, genome)
		local k, v
		local wanted = false
		for k,v in pairs(genome) do
			local tr = translations[k]
			if (tr) then 
				if (tr.f ~= nil) then 
					v = (tr.f) (v) 
				end
				if (tr.v ~= nil) then v = tr.v[v] or v end
				local name = "Bee Sample - " .. (tr.n) .. ": " .. v
				local s = seen[name] or 0
				if (s < 2) then 
					wanted = true 
					break
				end
			else 
				print ("Unknown trait " .. k .. " encountered")
			end
		end
		return wanted
	end
	
end

function unsafeBee (bee)
	if (   bee.individual.active.effect == "effect.meteor.name"
		) then
		return true
	end
	return false
end
		
function processInventory (config, scorers) 
	local imprinter = config.imprinter
	local tr, side = next(config.storage)
	invalidateAll()
	print ("Inventory scan using " .. tr .. "-" .. side)
	local a = getTransposer(config, tr)
	local cSize = a.getInventorySize (sides[side])
	local inv = {}
	local seen = {}
	local catalog = startCatalog(config, scorers)
	for idx = 1, cSize do
		local item = getBee(config, idx, true)
		if (item ~= nil) then
			if item.name == "forestry:bee_queen_ge" or item.name == "forestry:bee_princess_ge" or item.name == "forestry:bee_drone_ge" then
				if not item.individual.isAnalyzed then
					pushToAnalyzer(config, idx)
				else
					addCatalog (catalog, item)
				end
			elseif item.name == "gendustry:gene_sample" then
				local lbl = item.label
				seen[lbl] = (seen[lbl] or 0) + 1
				if (seen[lbl] > 2) then
					if (config.furnace ~= nil) then
						-- send surplus sample to be cleaned
						local tr1 = getTransposer(config, config.furnace.transposer)
						local iside = config.storage[config.furnace.transposer]
						local ok = tr1.transferItem(sides[iside], sides[config.furnace.side], 1, idx)
						invalidate(idx)
						if (ok) then 
							seen[lbl] = seen[lbl] - 1
						end
					end
				end
			else 
				if (config.interface ~= nil) then
					local tr1 = getTransposer(config, config.interface.transposer)
					local iside = config.storage[config.interface.transposer]
					tr1.transferItem(sides[iside], sides[config.interface.side], 64, idx)
					invalidate(idx)
				end
			end
		end
		memWait()
	end
	return catalog, seen
end

function scanApiaries(config)
	local apiaries = config.apiaries
	local messages = {}
	local ready = {}
	for _, inv in pairs (apiaries) do
		local a = getTransposer(config, inv.transposer)
		-- remove product
		for slot = 7, 15 do 
			item = a.getStackInSlot(sides[inv.side], slot)
			if (item ~= nil) then 
				a.transferItem(sides[inv.side], sides[config.storage[inv.transposer]], 64, slot)
			end
		end
		-- mark ready if no queen
		local queen = a.getStackInSlot(sides[inv.side], 1)
		if queen == nil then
			table.insert (messages, inv.transposer .. "-" .. inv.side .. " (" .. inv.biome .. ")" )
			table.insert ( ready, inv )
		end
		local drone = a.getStackInSlot(sides[inv.side], 2)
		if drone ~= nil then
			print ( "Apiary at " .. inv.transposer .. "-" .. inv.side .. " has surplus drone(s) " )
			a.transferItem(sides[inv.side], sides[config.storage[inv.transposer]], drone.size, 2)
		end
		memWait()
	end
	if #messages > 0 then print ("Ready apiaries: " .. table.concat(messages, ", ")) end
	return ready
end

function scanAnalyzers(config)
	local analyzers = config.analyzers
	if analyzers == nil then return end
	local ready = {}
	for _, a in pairs (analyzers) do
		local tr1 = getTransposer(config, a.transposer)
		-- remove analyzed bees
		for slot = 9, 12 do 
			item = tr1.getStackInSlot(sides[a.side], slot)
			if (item ~= nil) then 
				tr1.transferItem(sides[a.side], sides[config.storage[a.transposer]], 64, slot)
			end
		end
	end
end	

function pushToAnalyzer(config, idx)
	scanAnalyzers(config)
	if config.analyzer_input ~= nil then
		local a = config.analyzer_input
		local tr1 = getTransposer(config, a.transposer)
		if (tr1.transferItem(sides[config.storage[a.transposer]], sides[a.side], 64, idx)) then
			invalidate(idx)
			return true
		else
			return false
		end
	end
	
	local analyzers = config.analyzers
	for _, a in pairs (config.analyzers) do
		local tr1 = getTransposer(config, a.transposer)
		for slot = 3, 8 do
			local inslot = tr1.getStackInSlot(sides[a.side], slot)
			if inslot == nil then
				tr1.transferItem(sides[config.storage[a.transposer]], sides[a.side], 64, idx)
				invalidate(idx)
				return true
			end
		end
	end
end
				
function breedBees(config, apiary, princess, drone)
	local tr1 = getTransposer(config, apiary.transposer)
	local iside = config.storage[apiary.transposer]
	if (princess.slot > 0 and drone.slot > 0 and 
		(apiary.unsafeok or checkBeeSafe(config, princess)) and
		nil == tr1.getStackInSlot(sides[apiary.side], 1) and
		nil == tr1.getStackInSlot(sides[apiary.side], 2)) then
		print ( "Loading apiary at " .. apiary.transposer .. "-" .. apiary.side )
		if (tr1.transferItem(sides[iside], sides[apiary.side], 1, princess.slot, 1) and	
			tr1.transferItem(sides[iside], sides[apiary.side], 1, drone.slot,    2)) then
			invalidate(princess.slot)
			invalidate(drone.slot)
			princess.slot = -1
			drone.slot = -1
			return true
		end
	end
	return false
end

function breedQueen(config, apiary, queen)
	local tr1 = getTransposer(config, apiary.transposer)
	local iside = config.storage[apiary.transposer]
	if (queen.slot > 0 and
		nil == tr1.getStackInSlot(sides[apiary.side], 1) and
		nil == tr1.getStackInSlot(sides[apiary.side], 2)) then
		print ( "Loading apiary at " .. apiary.transposer .. "-" .. apiary.side )
		if (tr1.transferItem(sides[iside], sides[apiary.side], 1, queen.slot,     1)) then
			invalidate(queen.slot)
			queen.slot = -1
		end
	end
end

function choose(list1, list2)
	local i = 1
	local j = 1
	local n1 = #list1
	local n2 = #list2
	return function ()
		if (i > n1) then return nil end
		local r = {list1[i], list2[j]}
		j = j + 1
		if j > n2 then
			j = 1
			i = i + 1
		end
		return r
	end
end
		
  -- local newList = {}
  -- if list2 then
    -- for i = 1, #list2 do
      -- for j = 1, #list1 do
        -- if list1[j] ~= list2[i] then
          -- table.insert(newList, {list1[j], list2[i]})
        -- end
      -- end
    -- end
  -- else
    -- for i = 1, #list1 do
      -- for j = i, #list1 do
        -- if list1[i] ~= list1[j] then
          -- table.insert(newList, {list1[i], list1[j]})
        -- end
      -- end
    -- end
  -- end
  -- return newList
-- end

function filterByBiome(config, beeNames, biome, bees)
	local filtered = {}
	for _, slot in pairs(bees) do
		memWait()
		local bee = getBee(config, slot, false)
		if bee ~= nil and beeNames[bee.individual.active.species] == biome then
			table.insert(filtered,bee)
		end
	end
	return filtered
end

function fixName(name)
	return name.name
end

function fixParents(parents)
  parents.allele1 = fixName(parents.allele1)
  parents.allele2 = fixName(parents.allele2)
  if parents.result then
    parents.result = fixName(parents.result)
  end
  return parents
end

function getBees(config, list)
	local result = {}
	for _, slot in pairs(list) do
		memWait()
		local bee = getBee (config, slot, false)
		if bee ~= nil then table.insert(result, bee) end
	end
	return result
end

function getBeeMap(config, list)
	local result = {}
	for _, slot in pairs(list) do
		memWait()
		local bee = getBee (config, slot, false)
		if bee ~= nil then result[slot]=bee end
	end
	return result
end

-- selects best pair for target species
--   or initiates breeding of lower species
function selectPair(config, beeNames, mutations, scorers, catalog, targetSpecies, biome)
	local baseChance = 0
	-- local p = getBeeParents(targetSpecies)
	-- if #p > 0 then
		-- local parents = p[1]
		-- baseChance = parents.chance	
	-- end
	local haveReference = (catalog.referencePrincessesBySpecies[targetSpecies] ~= nil and
						   catalog.referenceDronesBySpecies[targetSpecies] ~= nil)
	local mateCombos = choose(catalog.princesses, catalog.drones)
	local selectedMate = nil
	for v in mateCombos do
		local princess = v[1] 
		local drone = v[2]
		if (princess ~= nil and drone ~= nil and princess.slot > 0 and drone.slot > 0 and biome == beeNames[princess.individual.active.species]) then
			local baseChance = mutateSpeciesChance(mutations, princess.individual.active.species, drone.individual.active.species, targetSpecies)
			local chance = mutateBeeChance(mutations, princess, drone, targetSpecies) or 0
			-- print ( ">> " .. princess.label .. " x " .. drone.label .. " -> " .. targetSpecies .. " = " .. chance)
			if (chance > 0 and (((not haveReference and chance >= baseChance / 2) or (haveReference and chance > 25)))) then				
				local newMate = {
					["princess"] = princess,
					["drone"] = drone,
					["speciesChance"] = chance
				  }
				for trait, scorer in pairs(scorers) do
					newMate[trait] = (scorer(princess) + scorer(drone)) / 2
				end		
				if (selectedMate == nil or compareMates(newMate, selectedMate)) then
					-- print ("Candidate found, " .. princess.label .. " x " .. drone.label .. " -> " .. targetSpecies)
					selectedMate = newMate
				end
			end
		end
	end
				
	return selectedMate
end

function selectPairForMutator(config, beeNames, mutations, scorers, catalog, targetSpecies)
	local baseChance = 0
	memWait()
	local selectedMate = nil
	local mateCombos = choose(catalog.princesses, catalog.drones)
	for v in mateCombos do
		local princess = v[1] 
		local drone = v[2]
		if (princess ~= nil and drone ~= nil and princess.slot > 0 and drone.slot > 0 and 
			princess.individual.active.species ~= targetSpecies and drone.individual.active.species ~= targetSpecies) then
			local chance = mutateSpeciesChance(mutations, princess.individual.active.species, drone.individual.active.species, targetSpecies)
			if chance > 0 then 
				local newMate = {
					["princess"] = princess,
					["drone"] = drone,
					["speciesChance"] = chance
				  }
				for trait, scorer in pairs(scorers) do
					newMate[trait] = (scorer(princess) + scorer(drone)) / 2
				end		
				if (selectedMate == nil or not compareMates(newMate, selectedMate)) then -- use WORST pairing
					-- print ("Candidate found, " .. princess.label .. " x " .. drone.label .. " -> " .. targetSpecies)
					selectedMate = newMate
				end	
			end
		end
	end
	
	return selectedMate
end

function checkBeeSafe (config, bee)
	clearMachines(config)
	if (bee.slot ~= -1 and (bee.name == "forestry:bee_princess_ge") and unsafeBee(bee)) then
		local imprinter = config.imprinter
		if imprinter ~= nil then
			local tr1 = getTransposer(config, imprinter.transposer)
			local iside = config.storage[imprinter.transposer]
			if (tr1.getStackInSlot(sides[imprinter.side], 1) ~= nil and
				tr1.getStackInSlot(sides[imprinter.side], 2) ~= nil and
				tr1.getStackInSlot(sides[imprinter.side], 3) == nil) then
				print ("Sending " .. bee.label .. " to be imprinted")
				if (tr1.transferItem(sides[iside], sides[imprinter.side], 1, bee.slot)) then 
					invalidate(bee.slot)
					bee.slot = -1
				end
			end
		end
		return false
	else 
		return true
	end
end

-- selects best pair for target species
--   or initiates breeding of lower species
function expandTargetSpecies(beeNames, mutations, scorers, catalog, targetSpecies)
	local parentss = getBeeParents(targetSpecies)
	local ret2 = {}
	parentss.n = nil
	if #parentss > 0 then
		  --print(textutils.serialize(catalog.referencePrincessesBySpecies))
		local trySpecies = {}
		for i, parents in ipairs(parentss) do
			fixParents(parents)
			trySpecies[parents.allele2] = true
			trySpecies[parents.allele1] = true
		end
		for species, _ in pairs(trySpecies) do
			table.insert (ret2, species)
		end
	end
	return ret2
end

function isPureBred(bee1, bee2, targetSpecies)
  if bee1 == nil or bee2 == nil then
    return false
  elseif bee1.individual.isAnalyzed and bee2.individual.isAnalyzed then
    if bee1.individual.active.species == bee1.individual.inactive.species and
        bee2.individual.active.species == bee2.individual.inactive.species and
        bee1.individual.active.species == bee2.individual.active.species and
        (targetSpecies == nil or bee1.individual.active.species == targetSpecies) then
      return true
    end
  elseif bee1.individual.isAnalyzed == false and bee2.individual.isAnalyzed == false then
    if bee1.individual.displayName == bee2.individual.displayName then
      return true
    end
  end
  return false
end

function breedTargetSpecies(config, beeNames, mutations, catalog, apiaries, scorers, targetSpecies)
	memWait()

	if config.mutator ~= nil then
		clearMachines(config)
		local mutator = config.mutator
		local tr1 = getTransposer(config, mutator.transposer)
		local iside = config.storage[mutator.transposer]

		-- print ("mutator slot 4: " .. ser.serialize(tr1.getStackInSlot(sides[mutator.side], 4)))
		
		if (tr1.getStackInSlot(sides[mutator.side], 1) == nil and
			tr1.getStackInSlot(sides[mutator.side], 2) == nil and
			tr1.getStackInSlot(sides[mutator.side], 4) ~= nil) then
		
			local mates = selectPairForMutator(config, beeNames, mutations, scorers, catalog, targetSpecies)

			if mates ~= nil then 
				if (tr1.transferItem(sides[iside], sides[mutator.side], 1, mates.princess.slot, 1) and	
					tr1.transferItem(sides[iside], sides[mutator.side], 1, mates.drone.slot,    2)) then
					invalidate(mates.princess.slot)
					invalidate(mates.drone.slot)
					mates.princess.slot = -1
					mates.drone.slot = -1
					print ("Breeding " .. mates.princess.label .. " and " .. mates.drone.label .. " using mutator, target is " .. targetSpecies)
				end
			end
		end
	end
	
	local biomeList = {}
	
	for _, apiary in pairs(apiaries) do
		if biomeList[apiary.biome] == nil then
			biomeList[apiary.biome] = apiary.biome
		end
	end

	for biome, _ in pairs(biomeList) do
		memWait()
		local mates = selectPair(config, beeNames, mutations, scorers, catalog, targetSpecies, biome)
		if mates ~= nil then
			for _, apiary in pairs(apiaries) do
				if apiary.biome == biome then
					local tr1 = getTransposer(config, apiary.transposer)
					if (nil == tr1.getStackInSlot(sides[apiary.side], 1) and
						nil == tr1.getStackInSlot(sides[apiary.side], 2)) then
						if breedBees(config, apiary, mates.princess, mates.drone) then
							print ("Breeding " .. mates.princess.label .. " and " .. 			mates.drone.label .. ", target is " .. targetSpecies)
						end
					end	
				end
			end
		end
	end
end		

function breedAllSpecies(config, beeNames, mutations, catalog, apiaries, scorers, speciesList)

    for _, targetSpecies in pairs(speciesList) do
		breedTargetSpecies(config, beeNames, mutations, catalog, apiaries, scorers, targetSpecies) 
	end
end

function run (beeNames, mutations, scorers) 

	local config = loadFile("beeManager.config")
	
	if config == nil then
		print ("Configuration not loaded!")
		return
	else 
		print ("Configuration loaded.")
	end
	
	-- scan apiaries
	
	scanApiaries(config)

	-- scan analyzers
	
	scanAnalyzers(config)

	clearMachines(config)
	
	-- catalog bees
	
	local catalog, seen = processInventory (config, scorers)
	
	print ("Inventory scan: ".. #catalog.bees .. " bees found")

	memWait()
	
	surplus = finishCatalog (catalog)

	inv = nil
	
	memWait()
	
	if (config.sampler ~= nil ) then
		local tr1 = getTransposer(config, config.sampler.transposer)
		local iside = config.storage[config.sampler.transposer]
		local tside = config.sampler.side

		if (tr1.getStackInSlot(sides[tside], 4) ~= nil) then
			tr1.transferItem(sides[tside], sides[iside], 1, 4)
		end

		local sampleCount = 0

		while (#surplus > 0) do
			local s = table.remove(surplus)
			local bee = getBee(config, s, true)
			if (bee ~= nil and (traits_wanted(seen, bee.individual.active) or traits_wanted(seen, bee.individual.inactive))) then
				if (tr1.getStackInSlot(sides[tside], 4) ~= nil) then
					tr1.transferItem(sides[tside], sides[iside], 1, 4)
				end
				if (tr1.getStackInSlot(sides[tside], 3) == nil and tr1.transferItem(sides[iside], sides[tside], 1, s, 3)) then
					print ( "Sampling a surplus bee" )
				else
					sampleCount = sampleCount + 1
				end
			elseif config.junk ~= nil then
				for _,j in pairs(config.junk) do
					local tr1 = getTransposer(config, j.transposer)
					local iside = config.storage[j.transposer]
					if (tr1.transferItem(sides[iside], sides[j.side], 64, s)) then 
						invalidate(s)
						break 
					end
				end
			end
		end
		
		print ("Surplus drones remaining to sample: " .. sampleCount)
		
		memWait()
	end

	for _, apiary in pairs(config.apiaries) do
		for _, slot in pairs(catalog.queens) do
			queen = getBee(config, slot, true)
			if (queen ~= nil and 
				queen.individual ~= nil and 
				beeNames[queen.individual.active.species] == apiary.biome and
				(apiary.unsafeok or not unsafeBee(queen))) then 
				breedQueen ( config, apiary, queen ) 
			end
		end
	end
	
	local completeMap = {}
	
	for species, _ in pairs(beeNames) do
		local haveReference = (catalog.referencePrincessesBySpecies[species] ~= nil and
							   catalog.referenceDronesBySpecies[species] ~= nil and
							   isPureBred(getBee(config, catalog.referencePrincessesBySpecies[species], false), 
										  getBee(config, catalog.referenceDronesBySpecies[species], false)))
		
		if haveReference then 
			completeMap[species] = species
		end
	end
	
	local inProgressMap = {}
	local noBiomeMap = {}
		
	for species, _ in pairs(catalog.princessesBySpecies) do
		if completeMap[species] == nil then inProgressMap[species] = species end
		if beeNames[species] == "?" then noBiomeMap[species] = species end
	end
		
	for species, _ in pairs(catalog.dronesBySpecies) do
		if completeMap[species] == nil then inProgressMap[species] = species end
		if beeNames[species] == "?" then noBiomeMap[species] = species end
	end
	
	local biomeCnt = {}
	
	for species, _ in pairs(completeMap) do
		if (mutations[species] ~= nil) then 
			local mutatesTo = mutations[species].mutateTo
			for nxt, oth in pairs(mutatesTo) do
				for species2, _ in pairs(oth) do
					if completeMap[species2] and not completeMap[nxt] then 
						inProgressMap[nxt] = nxt 
						if beeNames[nxt] == "?" then noBiomeMap[nxt] = nxt end
						biomeCnt[beeNames[nxt]] = 1 + (biomeCnt[beeNames[nxt]] or 0)
					end
				end
			end
		end
	end
	
	local complete = {}
	local inProgress = {}
	local noBiome = {}
	
	for s, _ in pairs (completeMap) do table.insert ( complete, s ) end
	for s, _ in pairs (inProgressMap) do table.insert ( inProgress, s ) end
	for s, _ in pairs (noBiomeMap) do table.insert (noBiome, s ) end
	
	local biomeReqStr = ""
	for b, n in pairs (biomeCnt) do biomeReqStr = biomeReqStr .. " " .. b .. ":" .. n end
	
	print ("Complete species: " .. table.concat ( complete, ", " ) )
	print ("In progress: " .. table.concat ( inProgress, ", " ) )
	print ("Apiaries needed by biome type: " .. biomeReqStr )
	
	inProgress = shuffle(inProgress)
	
	local targetList = {}
	
	for _, species in ipairs(config.targetSpecies) do
		if completeMap[species] == nil then
			table.insert (targetList, species)
		end
	end
	
	for _, species in ipairs (inProgress) do
		table.insert (targetList, species)
	end
	
	print ("Target list: " .. table.concat ( targetList, ", " ) )
	
	breedAllSpecies (config, beeNames, mutations, catalog, config.apiaries, scorers, targetList) 

	for _, species in pairs(complete) do
		if (nil ~= catalog.dronesBySpecies[species]) then
			local princess = getBee(config, catalog.referencePrincessesBySpecies[species], false)
			local drone =    getBee(config, catalog.referenceDronesBySpecies[species], false)
			for _, apiary in ipairs(config.apiaries) do
				local tr1 = getTransposer(config, apiary.transposer)
				if (nil == tr1.getStackInSlot(sides[apiary.side], 1) and
					nil == tr1.getStackInSlot(sides[apiary.side], 2) and 
					beeNames[species] == apiary.biome) then
					print ("Breeding " .. princess.label .. " and " .. drone.label .. " (reference for " .. species .. ")")
					breedBees(config, apiary, princess, drone) 
				end
			end
		end
	end	
		
	print ("Missing biome list: " .. table.concat ( noBiome, ", " ) )
	
end

scorers = buildScoring()

while true do
	beeNames = loadFile("beeNames.txt")
	run(beeNames, mutations, scorers)
	memWait()
end
