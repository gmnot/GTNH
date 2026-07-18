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

local threshold = 7615776  -- best for Sh

-- The forge changes antimatter on tick 1. Pull after that, return before the next tick 1.
-- Missing a return only idles the forge; missing a pull before the next tick 1 can lose a lot.
local takeProgressMin = 2
local machineCycleTicks = 20
-- getWorkProgress is one ahead of the displayed machine tick.
local putTick = 16
local putProgressMin = putTick + 1

-- Print every N cycles.
local printEvery = 1

-- Warn if returned amount is much lower than previous kept amount.
local abnormalLoss = threshold / 300

-- Safety timeout for startup / wrong side / missing seed fluid.
local tankWaitTimeout = 5

-- Max wait before pulling tank during stop.
local stopWaitTimeout = 3

-- Wait between transfer retries while the forge is safely stopped.
local transferRetryDelay = 1

-- Yield every N tight-loop iterations.
local yieldEvery = 80

local cycle = 0
local lastKeep = nil
local totalIncAmount = 0
local totalInputAmount = 0

-- Two redstone input sides are required.
local controlSides = nil

local gtmMachine = nil
local gtmTank = nil
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

local function formatPercent(value)
  return string.format("%6.2f%%", value * 100)
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
  requireMethod(gtmMachine, "isWorkAllowed", "antimatterForge")
  requireMethod(gtmMachine, "getWorkProgress", "antimatterForge")
  requireMethod(gtmTank, "setWorkAllowed", "tank")

  print("[init] forge=" .. tostring(gtmMachine))
  print(
    "[init] tank=" ..
    tostring(invoke(gtmTank, "getName"))
  )
end

local function setMachineAllowed(value)
  invoke(gtmMachine, "setWorkAllowed", value)
end

local function setTankAllowed(value)
  invoke(gtmTank, "setWorkAllowed", value)
end

local function isMachineAllowed()
  return not not invoke(gtmMachine, "isWorkAllowed")
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

local function stopMachineAndConfirm()
  local stoppedSamples = 0

  while true do
    -- Reassert the stop command in case another controller changed the state.
    setMachineAllowed(false)

    local allowed = isMachineAllowed()
    local p = progress()
    if not allowed and p == 0 then
      stoppedSamples = stoppedSamples + 1
      if stoppedSamples >= 2 then
        print("[recover] forge stop confirmed allowed=false progress=0")
        return
      end
    else
      stoppedSamples = 0
    end

    os.sleep(0.05)
  end
end

local function safeStop()
  pcall(setMachineAllowed, false)

  local startTime = computer.uptime()
  while progress() == 1 do
    if computer.uptime() - startTime > stopWaitTimeout then
      print("[warn] timeout waiting safe tick before tank stop")
      break
    end
    os.sleep(0)
  end

  pcall(setTankAllowed, false)
end

local function waitProgressAtLeastBeforeCycleEnd(target)
  while controlOn() do
    local p = progress()
    if p >= target then
      return p, true
    end
    if p < takeProgressMin then
      return p, false
    end
    os.sleep(0)
  end

  return nil, false
end

local function waitProgressBelow(target)
  while controlOn() do
    local p = progress()
    if p < target then
      return p
    end
    os.sleep(0)
  end

  return nil
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
    local p = progress()
    if p >= takeProgressMin then
      return p
    end
    os.sleep(0)
  end

  return nil
end

local function tryTransferExcess(sum)
  local keep, remove = keepRemove(sum)

  if remove > 0 then
    local ok, result, moved = pcall(trans.transferFluid, sideTank, sideOutput, remove)
    local remaining = tankLevel()

    if not ok or result == false or remaining > keep then
      return false, keep, remove, result, moved, remaining
    end
  end

  return true, keep, remove
end

local function recoverTransfer()
  print("[recover] transfer failed; stopping forge")
  stopMachineAndConfirm()

  -- Keep the tank disabled so all antimatter flows back into it.
  setTankAllowed(false)

  local sum, got = waitTankNonZero(nil)
  if not got then
    stopReason = "control off during transfer recovery"
    return nil, nil, false
  end

  print("[recover] forge stopped; antimatter returned to tank amount=" .. tostring(sum))

  while true do
    sum = tankLevel()
    local ok, keep, remove, result, moved, remaining = tryTransferExcess(sum)
    if ok then
      print(
        "[recover] transfer succeeded sum=" ..
        tostring(sum) ..
        " remove=" ..
        tostring(remove) ..
        " keep=" ..
        tostring(keep)
      )

      if not controlOn() then
        stopReason = "control off after transfer recovery"
        return keep, remove, false
      end

      -- Re-prime from the safe stopped state, then resume with a fresh cycle.
      setTankAllowed(true)
      if not waitTankEmpty() then
        stopReason = "control off while restarting after transfer recovery"
        return keep, remove, false
      end
      setMachineAllowed(true)
      print("[recover] forge restarted; returning to normal cycle")
      return keep, remove, true
    end

    print(
      "[recover] transfer retry remove=" ..
      tostring(remove) ..
      " result=" ..
      tostring(result) ..
      " moved=" ..
      tostring(moved) ..
      " tank=" ..
      tostring(remaining)
    )
    os.sleep(transferRetryDelay)
  end
end

local function transferExcess(sum)
  local ok, keep, remove, result, moved, remaining = tryTransferExcess(sum)
  if ok then
    return keep, remove, false, true
  end

  print(
    "[bad] transfer failed remove=" ..
    tostring(remove) ..
    " result=" ..
    tostring(result) ..
    " moved=" ..
    tostring(moved) ..
    " tank=" ..
    tostring(remaining)
  )

  local recoveredKeep, recoveredRemove, restarted = recoverTransfer()
  return recoveredKeep, recoveredRemove, true, restarted
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
  local putStartProgress = nil
  local putEndProgress = nil
  local takeStartProgress = nil
  local takeEndProgress = nil

  if firstCycleThisRun then
    setMachineAllowed(false)
    setTankAllowed(false)

    local sum, got = waitTankNonZero(tankWaitTimeout)
    if not got then
      printTankWaitFailure()
      stopReason = "tank wait failed"
      return false
    end

    local keep, remove, recovered, restarted = transferExcess(sum)
    if keep == nil or (recovered and not restarted) then
      return false
    end

    if not recovered then
      putStartProgress = progress()
      if putStartProgress >= takeProgressMin and putStartProgress < putProgressMin then
        local hitPutWindow = false
        putStartProgress, hitPutWindow = waitProgressAtLeastBeforeCycleEnd(putProgressMin)
        if putStartProgress == nil then
          stopReason = "control off before initial put window"
          return false
        end
        if not hitPutWindow then
          setMachineAllowed(false)
          stopReason = "missed initial put window"
          return false
        end
      end

      setTankAllowed(true)

      local emptied = waitTankEmpty()
      putEndProgress = progress()
      if not emptied then
        stopReason = "control off while priming tank"
        return false
      end

      setMachineAllowed(true)
    end

    lastKeep = keep
  else
    if waitProgressBelow(takeProgressMin) == nil then
      stopReason = "control off before next machine cycle"
      return false
    end
  end

  takeStartProgress = waitMachineStart()
  if takeStartProgress == nil then
    stopReason = "control off before machine take window"
    return false
  end

  cycle = cycle + 1

  -- Disable tank: pull antimatter back from hatches to tank after tick 1.
  setTankAllowed(false)

  local sum, got = waitTankNonZero(nil)
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
    setMachineAllowed(false)
    stopReason = "abnormal antimatter loss"
    return false
  end

  local keep, remove, recovered, restarted = transferExcess(sum)
  if keep == nil or (recovered and not restarted) then
    return false
  end
  if recovered then
    lastKeep = keep
    stopReason = "ok"
    return true
  end
  takeEndProgress = progress()

  local hitPutWindow = false
  putStartProgress, hitPutWindow = waitProgressAtLeastBeforeCycleEnd(putProgressMin)
  if putStartProgress == nil then
    stopReason = "control off before machine put window"
    return false
  end
  if not hitPutWindow then
    setMachineAllowed(false)
    stopReason = "missed machine put window"
    return false
  end

  -- Enable tank: distribute the trimmed antimatter back before the next tick 1.
  setTankAllowed(true)

  local emptied = waitTankEmpty()
  putEndProgress = progress()
  if not emptied then
    stopReason = "control off while emptying tank"
    return false
  end

  local inc = 0
  if lastKeep ~= nil then
    inc = sum - lastKeep
    totalIncAmount = totalIncAmount + inc
    totalInputAmount = totalInputAmount + lastKeep
  end
  local ave = 0
  if totalInputAmount > 0 then
    ave = totalIncAmount / totalInputAmount
  end
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
      ", ave=" ..
      formatPercent(ave) ..
      ", take " ..
      tostring(takeStartProgress) ..
      "-" ..
      tostring(takeEndProgress) ..
      " | put " ..
      tostring(putStartProgress) ..
      "-" ..
      tostring(putEndProgress)
    )
  end

  lastKeep = keep
  stopReason = "ok"
  return true
end

local function main()
  initGtMachines()
  initSides()

  print("[init] threshold=" .. tostring(threshold))
  print(
    "[init] take>=" ..
    tostring(takeProgressMin) ..
    ", put_tick=" ..
    tostring(putTick) ..
    ", put_progress>=" ..
    tostring(putProgressMin) ..
    ", tick_safe_return=" ..
    tostring(machineCycleTicks - putProgressMin)
  )
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
      os.sleep(1)
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
