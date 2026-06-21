local component = require("component")
local computer = require("computer")
local os = require("os")
local sides = require("sides")

if not component.isAvailable("transposer") then
  error("no transposer component")
end

if not component.isAvailable("redstone") then
  error("no redstone component")
end

local trans = component.transposer
local rs = component.redstone

-- Set these manually only if auto detection fails.
local sideTank = nil
local sideOutput = nil

local threshold = 2000000

-- Forge progress >= this is treated as active cycle.
local runningProgressMin = 2

-- Print every N cycles.
local printEvery = 1

-- Warn if returned amount is much lower than previous kept amount.
local abnormalLoss = 1000

-- Safety timeout for startup / wrong side / missing seed fluid.
local tankWaitTimeout = 5

-- Yield every N tight-loop iterations.
local yieldEvery = 80

local cycle = 0
local firstKeep = nil
local lastKeep = nil
local controlSide = nil

local gtmMachine = nil
local gtmTank = nil

local sideNames = {
  [sides.down] = "down",
  [sides.up] = "up",
  [sides.north] = "north",
  [sides.south] = "south",
  [sides.west] = "west",
  [sides.east] = "east",
}

local allSides = {
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

local function tryInvoke(addr, name, ...)
  local ok, result = pcall(component.invoke, addr, name, ...)
  if not ok then
    return false, result
  end
  return true, result
end

local function invoke(addr, name, ...)
  local ok, result = tryInvoke(addr, name, ...)
  if not ok then
    error(name .. " failed on " .. tostring(addr) .. ": " .. tostring(result))
  end
  return result
end

local function hasMethod(addr, name)
  local ok, methods = pcall(component.methods, addr)
  if not ok or methods == nil then
    return false
  end
  return methods[name] ~= nil
end

local function requireMethod(addr, name, label)
  if not hasMethod(addr, name) then
    error(label .. " missing method: " .. name)
  end
end

local function getTankInfoSafe(side)
  local ok, info = pcall(trans.getTankInfo, side)
  if not ok then
    return nil
  end
  return info
end

local function getTankLevelSafe(side)
  local ok, level = pcall(trans.getTankLevel, side)
  if not ok or level == nil then
    return 0
  end
  return tonumber(level) or 0
end

local function getTankCapacitySafe(side)
  local ok, cap = pcall(trans.getTankCapacity, side)
  if not ok or cap == nil then
    return 0
  end
  return tonumber(cap) or 0
end

local function extractTankName(info)
  if info == nil then
    return ""
  end

  for _, tank in pairs(info) do
    if type(tank) == "table" then
      if tank.name ~= nil then
        return tostring(tank.name)
      end
      if tank.label ~= nil then
        return tostring(tank.label)
      end
      if tank.fluidName ~= nil then
        return tostring(tank.fluidName)
      end
      if type(tank.fluid) == "table" and tank.fluid.name ~= nil then
        return tostring(tank.fluid.name)
      end
    end
  end

  return ""
end

local function hasAnyTankInfo(info)
  return info ~= nil and next(info) ~= nil
end

local function probeFluidSide(side)
  local info = getTankInfoSafe(side)
  local level = getTankLevelSafe(side)
  local cap = getTankCapacitySafe(side)
  local name = extractTankName(info)

  local hasFluid =
    hasAnyTankInfo(info) or
    cap > 0 or
    level > 0

  if not hasFluid then
    return nil
  end

  return {
    side = side,
    name = name,
    level = level,
    cap = cap,
  }
end

local function printFluidCandidates(items)
  print("[detect] fluid side candidates:")
  if #items == 0 then
    print("  none")
    return
  end

  for _, item in ipairs(items) do
    print(
      "  side=" .. sideName(item.side) ..
      ", name=" .. tostring(item.name) ..
      ", level=" .. tostring(item.level) ..
      ", cap=" .. tostring(item.cap)
    )
  end
end

local function collectFluidCandidates()
  local items = {}

  for _, side in ipairs(allSides) do
    local item = probeFluidSide(side)
    if item ~= nil then
      table.insert(items, item)
    end
  end

  return items
end

local function detectTankSide(items)
  if sideTank ~= nil then
    return sideTank
  end

  local nonZero = {}
  for _, item in ipairs(items) do
    if item.level > 0 then
      table.insert(nonZero, item)
    end
  end

  if #nonZero == 1 then
    return nonZero[1].side
  end

  local maxCap = -1
  local maxItems = {}

  for _, item in ipairs(items) do
    if item.cap > maxCap then
      maxCap = item.cap
      maxItems = { item }
    elseif item.cap == maxCap then
      table.insert(maxItems, item)
    end
  end

  if maxCap > 0 and #maxItems == 1 then
    return maxItems[1].side
  end

  print("[fatal] cannot uniquely detect quantum tank side")
  printFluidCandidates(items)
  error("set sideTank manually")
end

local function detectOutputSide(items, tankSide)
  if sideOutput ~= nil then
    return sideOutput
  end

  local candidates = {}

  for _, item in ipairs(items) do
    if item.side ~= tankSide then
      table.insert(candidates, item)
    end
  end

  if #candidates == 1 then
    return candidates[1].side
  end

  print("[fatal] cannot uniquely detect output side")
  printFluidCandidates(items)
  error("set sideOutput manually")
end

local function initSides()
  local items = collectFluidCandidates()

  sideTank = detectTankSide(items)
  sideOutput = detectOutputSide(items, sideTank)

  print("[init] tank side=" .. sideName(sideTank))
  print("[init] output side=" .. sideName(sideOutput))
end

local function initGtMachines()
  local list = {}

  for addr in component.list("gt_machine") do
    local name = tostring(invoke(addr, "getName"))

    table.insert(list, {
      address = addr,
      name = name,
    })
  end

  if #list ~= 2 then
    print("[fatal] expected exactly 2 gt_machine components, got " .. tostring(#list))
    for i, item in ipairs(list) do
      print("  [" .. tostring(i) .. "] " .. item.address .. " name=" .. item.name)
    end
    error("gt_machine count is not 2")
  end

  for _, item in ipairs(list) do
    if item.name == "antimatterForge" then
      if gtmMachine ~= nil then
        error("multiple antimatterForge components")
      end
      gtmMachine = item.address
    else
      if gtmTank ~= nil then
        error("multiple non-forge gt_machine components")
      end
      gtmTank = item.address
    end
  end

  if gtmMachine == nil then
    error("cannot find antimatterForge")
  end

  if gtmTank == nil then
    error("cannot find quantum tank gt_machine")
  end

  requireMethod(gtmMachine, "setWorkAllowed", "antimatterForge")
  requireMethod(gtmMachine, "getWorkProgress", "antimatterForge")
  requireMethod(gtmTank, "setWorkAllowed", "tank")

  print("[init] forge=" .. tostring(gtmMachine))
  print(
    "[init] tank=" ..
    tostring(gtmTank) ..
    " name=" ..
    tostring(invoke(gtmTank, "getName"))
  )
end

local function setMachineAllowed(value)
  invoke(gtmMachine, "setWorkAllowed", value)
end

local function setTankAllowed(value)
  invoke(gtmTank, "setWorkAllowed", value)
end

local function progress()
  return tonumber(invoke(gtmMachine, "getWorkProgress")) or 0
end

local function tankLevel()
  return getTankLevelSafe(sideTank)
end

local function findActiveControlSide()
  local found = nil
  local count = 0

  for _, side in ipairs(allSides) do
    local value = rs.getInput(side)
    if value > 0 then
      found = side
      count = count + 1
    end
  end

  if found == nil then
    return false
  end

  controlSide = found

  print("[init] control side=" .. sideName(controlSide))

  if count > 1 then
    print("[warn] multiple redstone input sides on; using " .. sideName(controlSide))
  end

  return true
end

local function controlOn()
  if controlSide == nil then
    return findActiveControlSide()
  end

  return rs.getInput(controlSide) > 0
end

local function stopAll()
  pcall(setMachineAllowed, false)
  pcall(setTankAllowed, false)
end

local function keepRemove(sum)
  local keep

  if sum > threshold then
    keep = threshold
  else
    keep = sum - (sum % 16)
  end

  if keep < 0 then
    keep = 0
  end

  return keep, sum - keep
end

local function waitTankNonZero(timeout)
  local startTime = computer.uptime()
  local i = 0

  while true do
    local amount = tankLevel()
    if amount > 0 then
      return amount, true
    end

    if timeout ~= nil and computer.uptime() - startTime > timeout then
      return 0, false
    end

    i = i + 1
    if i >= yieldEvery then
      i = 0
      if not controlOn() then
        return 0, false
      end
      os.sleep(0)
    end
  end
end

local function waitTankEmpty()
  local i = 0

  while true do
    local amount = tankLevel()
    if amount == 0 then
      return true
    end

    i = i + 1
    if i >= yieldEvery then
      i = 0
      if not controlOn() then
        return false
      end
      os.sleep(0)
    end
  end
end

local function waitMachineStart()
  while controlOn() do
    if progress() >= runningProgressMin then
      return true
    end
    os.sleep(0)
  end

  return false
end

local function waitMachineEnd()
  while controlOn() do
    if progress() < runningProgressMin then
      return true
    end
    os.sleep(0.05)
  end

  return false
end

local function transferExcess(sum)
  local keep, remove = keepRemove(sum)
  local transResult = "skip"

  if remove > 0 then
    local ok, result = pcall(trans.transferFluid, sideTank, sideOutput, remove)
    if not ok or result == false then
      print(
        "[bad] transfer failed remove=" ..
        tostring(remove) ..
        " result=" ..
        tostring(result)
      )
      error("transferFluid failed")
    end
    transResult = tostring(result)
  end

  return keep, remove, transResult
end

local function printTankWaitFailure()
  print("[bad] timeout waiting tank non-zero")
  print("[bad] tank side=" .. sideName(sideTank))
  print("[bad] tank level=" .. tostring(tankLevel()))
  print("[bad] forge progress=" .. tostring(progress()))
  printFluidCandidates(collectFluidCandidates())
  print("[bad] possible causes:")
  print("[bad] 1. quantum tank has no initial antimatter")
  print("[bad] 2. sideTank auto-detected incorrectly")
  print("[bad] 3. tank disable does not pull fluid back from hatches")
  print("[bad] 4. calibrator/cover mode or redstone behavior is wrong")
end

local function runOneBalance()
  cycle = cycle + 1

  local t0 = computer.uptime()

  -- Disable tank: pull antimatter back from hatches to tank.
  setTankAllowed(false)

  local timeout = nil
  if cycle == 1 then
    timeout = tankWaitTimeout
  end

  local sum, got = waitTankNonZero(timeout)
  if not got then
    printTankWaitFailure()
    return false
  end

  if lastKeep ~= nil and sum < lastKeep - abnormalLoss then
    print(
      "[bad] #" ..
      tostring(cycle) ..
      " low sum=" ..
      tostring(sum) ..
      " lastKeep=" ..
      tostring(lastKeep) ..
      " loss=" ..
      tostring(lastKeep - sum)
    )
  end

  local keep, remove, transResult = transferExcess(sum)

  -- Enable tank: distribute antimatter from tank to hatches.
  setTankAllowed(true)

  local emptied = waitTankEmpty()
  if not emptied then
    return false
  end

  setMachineAllowed(true)

  local started = waitMachineStart()
  if not started then
    return false
  end

  local ended = waitMachineEnd()
  if not ended then
    return false
  end

  if firstKeep == nil then
    firstKeep = keep
  end

  local dk = 0
  if lastKeep ~= nil then
    dk = keep - lastKeep
  end

  local total = keep - firstKeep
  local dt = computer.uptime() - t0

  if cycle % printEvery == 0 then
    print(
      "[cyc] #" ..
      tostring(cycle) ..
      " " ..
      tostring(sum) ..
      " = " ..
      tostring(keep) ..
      " + " ..
      tostring(remove) ..
      ", trans=" ..
      tostring(transResult) ..
      ", dk=" ..
      tostring(dk) ..
      ", total=" ..
      tostring(total) ..
      ", dt=" ..
      string.format("%.3f", dt)
    )
  end

  lastKeep = keep
  return true
end

local function main()
  initGtMachines()
  initSides()

  print("[init] threshold=" .. tostring(threshold))
  print("[init] waiting for control signal on any redstone side")

  stopAll()

  while true do
    if controlOn() then
      print("[start] signal on")

      setMachineAllowed(false)
      setTankAllowed(false)

      while controlOn() do
        local ok = runOneBalance()
        if not ok then
          break
        end
      end

      print("[stop] signal off")
      stopAll()
    else
      stopAll()
      os.sleep(1)
    end
  end
end

local ok, err = pcall(main)
if not ok then
  stopAll()
  print("[fatal] " .. tostring(err))
end