-- for 2.9.0 beta3

local os = require("os")
local component = require("component")
local sides = require("sides")
local term = require("term")
 
local transposer = component.transposer
local gtm = component.gt_machine
local UV = "molten.longasssuperconductornameforuvwire"
local UHV = "molten.longasssuperconductornameforuhvwire"
local UEV = "molten.superconductoruevbase"
local UIV = "molten.superconductoruivbase"
local UMV = "molten.superconductorumvbase"
 
-- Leave these nil for automatic detection. Set them only if the nearby tank
-- layout is more complicated than two stocked dual interfaces and one hatch.
local fluidInputSides = nil
local targetSide = nil
local superconductor = UV   -- Superconductor tier

local sideNames = {
  [sides.down] = "down",
  [sides.up] = "up",
  [sides.north] = "north",
  [sides.south] = "south",
  [sides.west] = "west",
  [sides.east] = "east"
}

local allSides = {sides.down, sides.up, sides.north, sides.south, sides.west, sides.east}
 
-- Fluid ID and output amount config (0-7, each signal can map to multiple fluids).
local fluids_by_signal = {
  [0] = {{id = "supercoolant", amount = 10000}},           -- 10000L supercoolant
  [1] = {{id = "helium", amount = 10000}},                 -- 10000L helium
  [2] = {{id = superconductor, amount = 1440}},            -- 1440L superconductor
  [3] = {{id = "neon", amount = 7500},                     -- 7500L neon + 1440L superconductor
         {id = superconductor, amount = 1440}}, 
  [4] = {{id = "molten.neutronium", amount = 4608}},       -- 4608L neutronium
  [5] = {{id = "krypton", amount = 5000},                  -- 5000L krypton + 4608L neutronium
         {id = "molten.neutronium", amount = 4608}}, 
  [6] = {{id = superconductor, amount = 1440},             -- 1440L superconductor + 4608L neutronium
         {id = "molten.neutronium", amount = 4608}}, 
  [7] = {{id = "xenon", amount = 2500},                    -- 2500L xenon + 1440L superconductor + 4608L neutronium
         {id = superconductor, amount = 1440},
         {id = "molten.neutronium", amount = 4608}} 
}

local expectedFluids = {}
for _, fluids in pairs(fluids_by_signal) do
  for _, fluid in ipairs(fluids) do
    expectedFluids[fluid.id] = true
  end
end

local function sideName(side)
  return (sideNames[side] or "unknown") .. "(" .. tostring(side) .. ")"
end

local function tankCount(side)
  local ok, count = pcall(transposer.getTankCount, side)
  return ok and type(count) == "number" and count or 0
end

local function detectSides()
  if fluidInputSides and targetSide then return end

  local sources, handlers = {}, {}
  for _, side in ipairs(allSides) do
    local count = tankCount(side)
    if count > 0 then
      handlers[#handlers + 1] = side
      for tank = 1, count do
        local ok, fluid = pcall(transposer.getFluidInTank, side, tank)
        if ok and fluid and expectedFluids[fluid.name] and (fluid.amount or 0) > 0 then
          sources[#sources + 1] = side
          break
        end
      end
    end
  end

  local inputs = fluidInputSides or sources
  if #inputs ~= 2 or inputs[1] == inputs[2] then
    error("cannot identify both stocked dual interfaces; found " .. #sources ..
      " sides with expected fluids. Stock both interfaces, then restart")
  end

  local output = targetSide
  if not output then
    local candidates = {}
    for _, side in ipairs(handlers) do
      if side ~= inputs[1] and side ~= inputs[2] then
        candidates[#candidates + 1] = side
      end
    end
    if #candidates ~= 1 then
      error("cannot identify unique fluid input hatch; found " .. #candidates ..
        " other tank sides. Set targetSide explicitly")
    end
    output = candidates[1]
  end
  if output == inputs[1] or output == inputs[2] then
    error("fluid input and output sides overlap")
  end

  fluidInputSides, targetSide = inputs, output
  print("[init] dual interfaces: " .. sideName(inputs[1]) .. ", " .. sideName(inputs[2]))
  print("[init] fluid input hatch: " .. sideName(output))
end

local function readControlSignal(info)
  -- 2.9's degasser exposes its signal in getInfoData/getSensorInformation.
  -- This also handles a zero signal without guessing which redstone face is wired.
  for _, raw in ipairs(info) do
    local line = tostring(raw):gsub("\194\167.", "")
    local lower = line:lower()
    if lower:find("purification_unit_degasser.control_signal", 1, true)
      or lower:find("control signal", 1, true)
      or line:find("控制信号", 1, true) then
      local bits = line:match("([01]+)%D*$")
      if bits and #bits <= 4 then return tonumber(bits, 2) end
    end
  end
  return nil
end

local function readSuccessRate(info)
  for _, raw in ipairs(info) do
    local line = tostring(raw):gsub("\194\167.", "")
    local lower = line:lower()
    if lower:find("success", 1, true) or line:find("成功", 1, true) then
      local rate = line:match("([%d%.]+)%s*%%")
      if rate then return tonumber(rate) end
    end
  end
  local oldLine = tostring(info[2] or ""):gsub("\194\167.", "")
  return tonumber(oldLine:match("([%d%.]+)%s*%%") or oldLine:match("%d+"))
end

-- Print fluids visible to the transposer.
local function printReadableFluids()
  print("Readable fluids:")

  for _, fluidSide in ipairs(fluidInputSides) do
    local sideName = sideNames[fluidSide] or tostring(fluidSide)
    local tankCount = transposer.getTankCount(fluidSide)

    print(string.format("Side %s: %s fluid tanks", sideName, tostring(tankCount)))

    for tank = 1, tankCount do
      local fluidInfo = transposer.getFluidInTank(fluidSide, tank)

      if fluidInfo and fluidInfo.name then
        print(string.format(
          "  tank %d: %s = %d / %d mB",
          tank,
          fluidInfo.name,
          fluidInfo.amount or 0,
          fluidInfo.capacity or 0
        ))
      end
    end
  end
end
 
-- Find the fluid tank and check whether enough fluid is available.
local function findFluidSlot(fluidId, requiredAmount)
  for _, fluidSide in ipairs(fluidInputSides) do
    local tankCount = transposer.getTankCount(fluidSide)
    for tank = 1, tankCount do
      local fluidInfo = transposer.getFluidInTank(fluidSide, tank)
      if fluidInfo and fluidInfo.name == fluidId and fluidInfo.amount >= requiredAmount then
        return fluidSide, tank - 1
      end
    end
  end
  return nil, nil
end

local function is_all_fluid_available()
  local max_required_by_fluid = {}

  for _, fluids in pairs(fluids_by_signal) do
    for _, fluidInfo in ipairs(fluids) do
      local currentMax = max_required_by_fluid[fluidInfo.id] or 0
      max_required_by_fluid[fluidInfo.id] = math.max(currentMax, fluidInfo.amount)
    end
  end

  for fluidId, requiredAmount in pairs(max_required_by_fluid) do
    local fluidSide, slot = findFluidSlot(fluidId, requiredAmount)
    if not fluidSide or not slot then
      return false, fluidId, requiredAmount
    end
  end

  return true
end
  
local function main()
  detectSides()
  local lastSignalStrength = -1
  local fluidTransferred = {}  -- Fluids that have already been transferred successfully.
 
  while true do
    local info = gtm.getSensorInformation()
    local signalStrength = type(info) == "table" and readControlSignal(info) or nil
    if signalStrength == nil then
      error("degasser control signal unavailable in machine sensor data; check the adapter and 2.9 sensor format")
    end
    
    if signalStrength ~= lastSignalStrength then
      term.clear()
      print("Red Stone Signal Changed: " .. lastSignalStrength .. " -> " .. signalStrength)
      printReadableFluids()
      lastSignalStrength = signalStrength  -- Update the last signal value.
      fluidTransferred = {}  -- Clear transfer records when the control signal changes.
    end

    local workProgress = gtm.getWorkProgress()  
    print(string.format("Work progress: %.2f s", workProgress / 20))

    local allFluidsAvailable, missingFluidId, requiredAmount = is_all_fluid_available()
    if not allFluidsAvailable then
      print(string.format("Missing fluid for max signal check: %s (need %d L)", missingFluidId, requiredAmount))
      print("Shutting down")
      gtm.setWorkAllowed(false)
      os.sleep(120)
    else
      print("All fluids available")
      -- since using center ctrl, can't turn on myself

      if signalStrength >= 8 then
        print("  Bit #4 is set. Standby..")
        os.sleep(30)
      else
        -- Get the success rate.
        if workProgress > 1 then
          local successRate = readSuccessRate(info)
          if successRate == nil then
            error("degasser success rate unavailable in machine sensor data")
          end
          print("Success rate = " .. successRate .. "%")
          if successRate >= 100 then
            print("waiting for next cycle.")
            fluidTransferred = {}
          else
            -- If the success rate is below 100, transfer fluids based on the control signal.
            if fluids_by_signal[signalStrength] then
              print("  Start transferring fluids:")
              for _, fluidInfo in ipairs(fluids_by_signal[signalStrength]) do
                local fluidId = fluidInfo.id
                local amount = fluidInfo.amount
                -- Skip fluids that have already been transferred.
                if fluidTransferred[fluidId] then
                  print(string.format("    Fluid %s has already been transferred, skipping", fluidId))
                else
                  local fluidSide, slot = findFluidSlot(fluidId, amount)
                  if fluidSide and slot then
                    local success, transferredAmount = transposer.transferFluid(fluidSide, targetSide, amount, slot)
                    if success then
                      print(string.format("    Fluid transferred successfully: %s requested %d L, transferred %d L", fluidId, amount, transferredAmount))
                      fluidTransferred[fluidId] = true  -- Record the transferred fluid.
                    end
                  else
                    print(string.format("    Not enough fluid, please check stock. Need: %s (%d L)", fluidId, amount))
                  end
                end
              end
            end
          end
        end
      end
    end
    os.sleep(5)
  end
end
 
main()
