local component = require("component")
local sides = require("sides")

local transposer = component.transposer

local sideNames = {
  [sides.down] = "down",
  [sides.up] = "up",
  [sides.north] = "north",
  [sides.south] = "south",
  [sides.west] = "west",
  [sides.east] = "east",
}

local sideList = {
  sides.down,
  sides.up,
  sides.north,
  sides.south,
  sides.west,
  sides.east,
}

local function sideName(side)
  return (sideNames[side] or "unknown") .. "(" .. tostring(side) .. ")"
end

local function safeCall(fn, ...)
  local ok, result = pcall(fn, ...)
  if ok then return result end
  return nil
end

print("Scanning fluids around transposer...")
print("Transposer: " .. tostring(transposer.address))

for _, side in ipairs(sideList) do
  local tankCount = safeCall(transposer.getTankCount, side)
  print("")
  print("Side " .. sideName(side) .. ": tanks=" .. tostring(tankCount or 0))

  if tankCount and tankCount > 0 then
    for tank = 1, tankCount do
      local fluid = safeCall(transposer.getFluidInTank, side, tank)
      if fluid and fluid.name then
        print(string.format(
          "  tank %d: %s, amount=%s, capacity=%s",
          tank,
          tostring(fluid.name),
          tostring(fluid.amount or 0),
          tostring(fluid.capacity or 0)
        ))
      else
        print("  tank " .. tostring(tank) .. ": empty")
      end
    end
  end
end

print("")
print("Scan complete.")
