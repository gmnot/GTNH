local os = require("os")
local component = require("component")
local sides = require("sides")
local term = require("term")
 
local redstone = component.redstone
local transposer = component.transposer
local gtm = component.gt_machine
local UV = "molten.longasssuperconductornameforuvwire"
local UHV = "molten.longasssuperconductornameforuhvwire"
local UEV = "molten.superconductoruevbase"
local UIV = "molten.superconductoruivbase"
local UMV = "molten.superconductorumvbase"
 
-- Configure redstone input and fluid output sides.
local inputSide = sides.down                      -- Redstone signal input side
local fluidInputSides = {sides.north, sides.up}   -- Fluid input sides
local targetSide = sides.down                     -- Fluid output side
local superconductor = UHV   -- Superconductor tier

local sideNames = {
  [sides.down] = "down",
  [sides.up] = "up",
  [sides.north] = "north",
  [sides.south] = "south",
  [sides.west] = "west",
  [sides.east] = "east"
}
 
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
 
local function main()
  local lastSignalStrength = -1
  local lastSuccessRate = -1
  local fluidTransferred = {}  -- Fluids that have already been transferred successfully.
 
  while true do
    -- Get the current redstone signal strength.
    local signalStrength = redstone.getInput(inputSide)
    
    if signalStrength ~= lastSignalStrength then
      term.clear()
      print("Red Stone Signal Changed: " .. lastSignalStrength .. " -> " .. signalStrength)
      printReadableFluids()
      lastSignalStrength = signalStrength  -- Update the last signal value.
      fluidTransferred = {}  -- Clear transfer records when the redstone signal changes.
    end

    print("Time: " .. os.date("%H:%M:%S"))
 
    if signalStrength >= 8 then
      print("  Bit #4 is set. Standby..")
      os.sleep(30)
    else
      -- Get the success rate.
      local info = gtm.getSensorInformation()
      local workProgress = gtm.getWorkProgress()  
 
      if workProgress > 1 and info[2] ~= nil then
        local successRate = tonumber(string.match(info[2], "%d+"))
        
        -- Check even if the success rate has not changed.
        if successRate ~= lastSuccessRate or successRate < 100 then
          print("Current success rate: " .. successRate .. "%")
          lastSuccessRate = successRate
 
          if successRate >= 100 then
            print("Success rate reached 100%, waiting for next cycle.")
            fluidTransferred = {}
          else
            -- If the success rate is below 100, transfer fluids based on the redstone signal.
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
                    local success = transposer.transferFluid(fluidSide, targetSide, amount, slot)
                    if success then
                      print(string.format("    Fluid %s transferred successfully (%d L)", fluidId, amount))
                      fluidTransferred[fluidId] = true  -- Record the transferred fluid.
                    end
                  else
                    print(string.format("    Not enough fluid %s, please check stock (need %d L)", fluidId, amount))
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
