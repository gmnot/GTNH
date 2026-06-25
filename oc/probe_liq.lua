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

local function isEmptyStack(stack)
  if stack == nil then
    return true
  end
  if type(stack) ~= "table" then
    return false
  end
  return stack.name == nil and stack.label == nil and stack.size == nil and stack.amount == nil
end

local function stackAmount(stack)
  return stack.size or stack.amount or stack.qty or stack.count or 0
end

local function stackName(stack)
  return stack.label or stack.name or stack.id or "unknown"
end

local function stackDetails(stack)
  if type(stack) ~= "table" then
    return tostring(stack)
  end

  local parts = {
    tostring(stackName(stack)),
    "x" .. tostring(stackAmount(stack)),
  }

  if stack.name ~= nil and stack.label ~= nil and stack.name ~= stack.label then
    table.insert(parts, "name=" .. tostring(stack.name))
  end
  if stack.damage ~= nil then
    table.insert(parts, "damage=" .. tostring(stack.damage))
  end
  if tonumber(stack.maxDamage) ~= nil and tonumber(stack.maxDamage) > 0 then
    table.insert(parts, "maxDamage=" .. tostring(stack.maxDamage))
  end

  return table.concat(parts, ", ")
end

local function printInventorySide(side)
  local size = safeCall(transposer.getInventorySize, side)
  print("  inventory slots=" .. tostring(size or 0))

  if size == nil or size <= 0 then
    return
  end

  local any = false
  for slot = 1, size do
    local stack = safeCall(transposer.getStackInSlot, side, slot)
    if not isEmptyStack(stack) then
      any = true
      print(string.format("    slot %d: %s", slot, stackDetails(stack)))
    end
  end

  if not any then
    print("    empty")
  end
end

local function hasMethod(addr, name)
  local methods = safeCall(component.methods, addr)
  return methods ~= nil and methods[name] ~= nil
end

local function printInterfaceMarkedItems()
  local found = false

  for addr in component.list("me_interface", true) do
    found = true
    print("")
    print("ME interface: " .. tostring(addr))

    if not hasMethod(addr, "getInterfaceConfiguration") then
      print("  no getInterfaceConfiguration method")
    else
      local any = false
      for slot = 1, 81 do
        local stack = safeCall(component.invoke, addr, "getInterfaceConfiguration", slot)
        if not isEmptyStack(stack) then
          any = true
          print(string.format("  config %d: %s", slot, stackDetails(stack)))
        end
      end

      if not any then
        print("  no marked items")
      end
    end
  end

  if not found then
    print("")
    print("ME interface: none")
  end
end

print("Scanning fluids and items around transposer...")
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

  printInventorySide(side)
end

printInterfaceMarkedItems()

print("")
print("Scan complete.")
