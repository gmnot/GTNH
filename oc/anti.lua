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

local threshold = 2193392

local inputFluids = {
  "temporalfluid",
  "spatialfluid",
  "molten.shirabon",
  "naquadah based liquid fuel mkvi (depleted)",
  "protomatter",
}

local inputFluidStopMin = math.sqrt(threshold) * 10
local inputFluidStartMin = math.sqrt(threshold) * 300

-- Forge progress >= this is treated as active cycle.
local runningProgressMin = 2

-- Print every N cycles.
local printEvery = 1

-- Warn if returned amount is much lower than previous kept amount.
local abnormalLoss = 1000

-- Safety timeout for startup / wrong side / missing seed fluid.
local tankWaitTimeout = 5

-- Max wait before pulling tank during stop.
local stopWaitTimeout = 3

-- Wait before retrying after input fluid shortage.
local inputLowRetryDelay = 300

-- Yield every N tight-loop iterations.
local yieldEvery = 80

local cycle = 0
local firstKeep = nil
local lastKeep = nil

-- Two redstone input sides are required.
local controlSides = nil

local gtmMachine = nil
local gtmTank = nil
local meInterface = nil
local nextInputOk = nil
local nextInputCheckTime = 0
local stopReason = "unknown"

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

local function lpad(value, width)
  local text = tostring(value)
  if string.len(text) >= width then
    return text
  end
  return string.rep(" ", width - string.len(text)) .. text
end

local function formatSeconds(value)
  return string.format("%.2f", value)
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

local function initMeInterface()
  if not component.isAvailable("me_interface") then
    error("no me_interface component")
  end

  local candidates = {}

  for addr in component.list("me_interface", true) do
    local methods = component.methods(addr)
    table.insert(candidates, { address = addr, methods = methods })

    if methods ~= nil and methods.getFluidsInNetwork ~= nil then
      meInterface = component.proxy(addr)
      print("[init] me_interface=" .. tostring(addr))
      print("[init] input fluid stop min=" .. string.format("%.2f", inputFluidStopMin))
      print("[init] input fluid start min=" .. string.format("%.2f", inputFluidStartMin))
      return
    end
  end

  print("[fatal] no me_interface with getFluidsInNetwork")
  for i, item in ipairs(candidates) do
    print("  [" .. tostring(i) .. "] " .. tostring(item.address))
    if item.methods ~= nil then
      for name in pairs(item.methods) do
        print("    method=" .. tostring(name))
      end
    end
  end

  error("me_interface missing method: getFluidsInNetwork")
end

local function getNetworkFluidAmounts()
  local fluids = meInterface.getFluidsInNetwork()
  local amounts = {}

  for _, fluid in ipairs(fluids) do
    if fluid.name ~= nil then
      amounts[fluid.name] = tonumber(fluid.amount) or 0
    end
  end

  return amounts
end

local function checkInputFluids(minAmount, reason)
  local amounts = getNetworkFluidAmounts()

  for _, fluidName in ipairs(inputFluids) do
    local amount = amounts[fluidName] or 0
    if amount <= minAmount then
      print(
        "[bad] input fluid low " ..
        tostring(reason) ..
        ": " ..
        fluidName ..
        " amount=" ..
        tostring(amount) ..
        " need>" ..
        string.format("%.2f", minAmount)
      )
      return false
    end
  end

  return true
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

local function isTankMachineName(name)
  local lname = string.lower(tostring(name))

  return
    string.find(lname, "quantum", 1, true) ~= nil or
    string.find(lname, "tank", 1, true) ~= nil or
    string.find(lname, "super", 1, true) ~= nil
end

local function printGtMachineList(list)
  print("[detect] gt_machine components:")
  for i, item in ipairs(list) do
    print(
      "  [" ..
      tostring(i) ..
      "] " ..
      tostring(item.address) ..
      " name=" ..
      tostring(item.name)
    )
  end
end

local function initGtMachines()
  local list = {}
  local nonForge = {}
  local tankCandidates = {}

  for addr in component.list("gt_machine") do
    local name = tostring(invoke(addr, "getName"))

    local item = {
      address = addr,
      name = name,
    }

    table.insert(list, item)

    if name == "antimatterForge" then
      if gtmMachine ~= nil then
        error("multiple antimatterForge components")
      end
      gtmMachine = addr
    else
      table.insert(nonForge, item)

      if isTankMachineName(name) then
        table.insert(tankCandidates, item)
      end
    end
  end

  if #list < 2 then
    print("[fatal] expected at least 2 gt_machine components, got " .. tostring(#list))
    printGtMachineList(list)
    error("not enough gt_machine components")
  end

  if gtmMachine == nil then
    printGtMachineList(list)
    error("cannot find antimatterForge")
  end

  if #tankCandidates == 1 then
    gtmTank = tankCandidates[1].address
  elseif #tankCandidates == 0 and #nonForge == 1 then
    gtmTank = nonForge[1].address
  else
    print("[fatal] cannot uniquely detect quantum tank gt_machine")
    printGtMachineList(list)
    error("cannot find unique tank gt_machine")
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

local function detectControlSides()
  local active = {}

  for _, side in ipairs(allSides) do
    local value = rs.getInput(side)
    if value > 0 then
      table.insert(active, side)
    end
  end

  if #active < 2 then
    return false
  end

  if #active > 2 then
    print("[fatal] expected exactly 2 redstone input sides, got " .. tostring(#active))
    for _, side in ipairs(active) do
      print("  active side=" .. sideName(side) .. ", value=" .. tostring(rs.getInput(side)))
    end
    error("too many redstone control inputs")
  end

  controlSides = {
    active[1],
    active[2],
  }

  print(
    "[init] control sides=" ..
    sideName(controlSides[1]) ..
    " + " ..
    sideName(controlSides[2])
  )

  return true
end

local function controlOn()
  if controlSides == nil then
    return detectControlSides()
  end

  return (
    rs.getInput(controlSides[1]) > 0 and
    rs.getInput(controlSides[2]) > 0
  )
end

local function forceStopAll()
  pcall(setMachineAllowed, false)
  pcall(setTankAllowed, false)
end

local function waitCurrentCycleEnd(timeout)
  local startTime = computer.uptime()

  while progress() >= runningProgressMin do
    if timeout ~= nil and computer.uptime() - startTime > timeout then
      return false
    end
    os.sleep(0.05)
  end

  return true
end

local function safeStop()
  pcall(setMachineAllowed, false)

  local ok, ended = pcall(waitCurrentCycleEnd, stopWaitTimeout)
  if ok and not ended then
    print("[warn] timeout waiting current cycle before tank stop")
  end

  pcall(setTankAllowed, false)
end

local function waitResetWindow(label)
  setMachineAllowed(false)

  local p = progress()
  if p >= runningProgressMin then
    print(
      "[sync] " ..
      label ..
      ": machine active, progress=" ..
      tostring(p) ..
      ", wait before reset"
    )

    while controlOn() and progress() >= runningProgressMin do
      os.sleep(0.05)
    end

    if not controlOn() then
      return false
    end

    print("[sync] machine cycle ended, safe to reset")
  end

  return true
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

local function waitMachineEndAndCheckInputs()
  local checked = false
  local inputOk = true
  local checkTime = 0

  while controlOn() do
    if not checked then
      local checkStart = computer.uptime()
      inputOk = checkInputFluids(inputFluidStopMin, "stop")
      checkTime = computer.uptime() - checkStart
      checked = true
    end

    if progress() < runningProgressMin then
      return true, inputOk, checkTime
    end

    os.sleep(0.05)
  end

  return false, inputOk, checkTime
end

local function transferExcess(sum)
  local keep, remove = keepRemove(sum)

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
  end

  return keep, remove
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

local function runOneBalance(firstCycleThisRun)
  local precheckTime = 0

  if nextInputOk == nil then
    local checkStart = computer.uptime()
    nextInputOk = checkInputFluids(inputFluidStartMin, "start")
    precheckTime = computer.uptime() - checkStart
  end

  if not nextInputOk then
    nextInputOk = nil
    nextInputCheckTime = 0
    stopReason = "input fluid low"
    return false
  end

  nextInputOk = nil
  nextInputCheckTime = 0

  local label = "reset"
  if firstCycleThisRun then
    label = "first reset"
  end

  local syncStart = computer.uptime()
  if not waitResetWindow(label) then
    stopReason = "control off during sync"
    return false
  end
  local syncTime = computer.uptime() - syncStart

  cycle = cycle + 1

  local t0 = computer.uptime()

  -- Disable tank: pull antimatter back from hatches to tank.
  setTankAllowed(false)

  local timeout = nil
  if firstCycleThisRun then
    timeout = tankWaitTimeout
  end

  local sum, got = waitTankNonZero(timeout)
  if not got then
    printTankWaitFailure()
    stopReason = "tank wait failed"
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

  local keep, remove = transferExcess(sum)

  -- Enable tank: distribute antimatter from tank to hatches.
  setTankAllowed(true)

  local emptied = waitTankEmpty()
  if not emptied then
    stopReason = "control off while emptying tank"
    return false
  end

  local resetTime = computer.uptime() - t0

  setMachineAllowed(true)

  local started = waitMachineStart()
  if not started then
    stopReason = "control off before machine start"
    return false
  end

  local ended, inputOk, checkTime = waitMachineEndAndCheckInputs()
  nextInputOk = inputOk
  nextInputCheckTime = checkTime
  if not ended then
    stopReason = "control off before machine end"
    return false
  end

  if firstKeep == nil then
    firstKeep = keep
  end

  local inc = 0
  if lastKeep ~= nil then
    inc = keep - lastKeep
  end

  local totInc = keep - firstKeep
  local totalTime = nextInputCheckTime + precheckTime + syncTime + resetTime
  local amountWidth = math.max(8, string.len(tostring(threshold)) + 2)
  local deltaWidth = math.max(6, amountWidth - 2)

  if cycle % printEvery == 0 then
    print(
      "[cyc] #" ..
      lpad(cycle, 4) ..
      " " ..
      lpad(sum, amountWidth) ..
      " - " ..
      lpad(remove, amountWidth) ..
      " = " ..
      lpad(keep, amountWidth) ..
      ", inc=" ..
      lpad(inc, deltaWidth) ..
      ", tot_inc=" ..
      lpad(totInc, deltaWidth) ..
      ", T=" ..
      formatSeconds(totalTime) ..
      " s (" ..
      formatSeconds(nextInputCheckTime) ..
      "+" ..
      formatSeconds(precheckTime) ..
      "+" ..
      formatSeconds(syncTime) ..
      "+" ..
      formatSeconds(resetTime) ..
      ")"
    )
  end

  lastKeep = keep
  stopReason = "ok"
  return true
end

local function main()
  initMeInterface()
  initGtMachines()
  initSides()

  print("[init] threshold=" .. tostring(threshold))
  print("[init] input fluids=" .. tostring(#inputFluids))
  print("[init] waiting for 2 redstone input sides")

  while true do
    if controlOn() then
      print("[start] both signals on")

      local firstCycleThisRun = true

      while controlOn() do
        local ok = runOneBalance(firstCycleThisRun)
        firstCycleThisRun = false

        if not ok then
          break
        end
      end

      print("[stop] " .. stopReason)
      safeStop()
      if stopReason == "input fluid low" then
        print("[wait] input fluid low, retry in " .. tostring(inputLowRetryDelay) .. " sec")
        os.sleep(inputLowRetryDelay)
      else
        os.sleep(1)
      end
    else
      safeStop()
      os.sleep(1)
    end
  end
end

local ok, err = pcall(main)
if not ok then
  forceStopAll()
  print("[fatal] " .. tostring(err))
end
