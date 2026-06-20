local component = require("component")
local computer = require("computer")
local os = require("os")
local sides = require("sides")

local tr = component.transposer

-- Redstone IO for pulsing antimatter hatches.
local antired = component.proxy("518913ad-f51f-41ed-a9b3-374452400895")

-- Redstone IO for pulsing quantum tank distribution.
local aered = component.proxy("5fa40a0a-beaf-4f32-978b-49168d7847aa")

-- Redstone IO for lever input.
local trig = component.proxy("94ab179f-7814-4245-a7cb-c0aadaa6df50")

-- Set this manually if more than one gt_machine is visible.
-- Leave nil if only the antimatter forge is visible.
local machineAddress = nil

local sidered = sides.up
local sideae = sides.up
local sidetp = sides.down
local trigside = sides.up

local threshold = 2000000

-- Progress window used for rebalancing.
local rebalanceProgressMin = 1
local rebalanceProgressMax = 9

-- Timing.
local pulseSeconds = 0.05
local tankCheckInterval = 0.05
local tankStableSamples = 2
local collectTimeout = 4
local outputTimeout = 3
local distributeTimeout = 4
local loopSleep = 0.02

-- Avoid spamming reset every tick. 0.20-0.35 is usually reasonable.
local rebalanceCooldown = 0.25

-- Diagnostics.
local logEveryReset = 10
local warnLossAmount = 1000
local warnLossStreakLimit = 5

local sideNames = {
  [sides.down] = "down",
  [sides.up] = "up",
  [sides.north] = "north",
  [sides.south] = "south",
  [sides.west] = "west",
  [sides.east] = "east",
}

local function sideName(side)
  return (sideNames[side] or "unknown") .. "(" .. tostring(side) .. ")"
end

local function tryInvoke(address, methodName, ...)
  local ok, result = pcall(component.invoke, address, methodName, ...)
  if not ok then
    return false, result
  end
  return true, result
end

local function invoke(address, methodName, ...)
  local ok, result = tryInvoke(address, methodName, ...)
  if not ok then
    error(
      tostring(methodName) ..
      " failed on " ..
      tostring(address) ..
      ": " ..
      tostring(result)
    )
  end
  return result
end

local function findMachineAddress()
  if machineAddress ~= nil and machineAddress ~= "" then
    return machineAddress
  end

  local candidates = {}

  for address in component.list("gt_machine") do
    local ok, name = tryInvoke(address, "getName")
    local nameText = ok and tostring(name) or "unknown"

    if nameText == "antimatterForge" then
      return address
    end

    table.insert(candidates, {
      address = address,
      name = nameText,
    })
  end

  if #candidates == 0 then
    error("no gt_machine component found")
  end

  if #candidates == 1 then
    print(
      "[warn] only one gt_machine found, using it: " ..
      candidates[1].address ..
      ", name=" ..
      candidates[1].name
    )
    return candidates[1].address
  end

  print("[fatal] multiple gt_machine components found:")
  for i, item in ipairs(candidates) do
    print(
      "  [" ..
      tostring(i) ..
      "] " ..
      item.address ..
      ", name=" ..
      item.name
    )
  end

  error("set machineAddress manually")
end

local gtmMachineAddress = findMachineAddress()

local function setMachineAllowed(allowed)
  invoke(gtmMachineAddress, "setWorkAllowed", allowed)
end

local function getProgress()
  local progress = invoke(gtmMachineAddress, "getWorkProgress")
  return tonumber(progress) or 0
end

local function getMachineInfo(methodName)
  local ok, value = tryInvoke(gtmMachineAddress, methodName)
  if not ok then
    return "err:" .. tostring(value)
  end
  return tostring(value)
end

local function leverOn()
  return trig.getInput(trigside) > 0
end

local function getTankLevel()
  return tonumber(tr.getTankLevel(sideae)) or 0
end

local function safeRedstoneOff()
  pcall(antired.setOutput, sidered, 0)
  pcall(aered.setOutput, sidered, 0)
end

local function stopAll()
  pcall(setMachineAllowed, false)
  safeRedstoneOff()
end

local function printDiagnosis(title, detail)
  print("========== DIAGNOSIS ==========")
  print("[diag] " .. tostring(title))
  print("[diag] detail=" .. tostring(detail))
  print("[diag] tankSide=" .. sideName(sideae))
  print("[diag] outputSide=" .. sideName(sidetp))
  print("[diag] redstoneSide=" .. sideName(sidered))
  print("[diag] trigSide=" .. sideName(trigside))
  print("[diag] tankLevel=" .. tostring(getTankLevel()))
  print("[diag] gtMachine=" .. tostring(gtmMachineAddress))
  print("[diag] progress=" .. tostring(getMachineInfo("getWorkProgress")))
  print("[diag] maxProgress=" .. tostring(getMachineInfo("getWorkMaxProgress")))
  print("[diag] isActive=" .. tostring(getMachineInfo("isMachineActive")))
  print("[diag] isWorkAllowed=" .. tostring(getMachineInfo("isWorkAllowed")))
  print("[diag] possible causes:")
  print("[diag] 1. antired UUID or sidered is wrong.")
  print("[diag] 2. Hatch calibrator input/output mode is wrong.")
  print("[diag] 3. Hatch calibrator redstone behavior is wrong.")
  print("[diag] 4. aered UUID or sidered is wrong.")
  print("[diag] 5. Quantum tank distribution path is not emptying.")
  print("[diag] 6. sideae is reading a different tank than expected.")
  print("[diag] 7. P2P/storage bus path does not cover all 16 hatches.")
  print("[diag] 8. Calibrators are too slow for this amount/TPS.")
  print("================================")
end

local function fatalStop(title, detail)
  stopAll()
  printDiagnosis(title, detail)
  error(title)
end

local function pulse(redstoneComp)
  redstoneComp.setOutput(sidered, 15)
  os.sleep(pulseSeconds)
  redstoneComp.setOutput(sidered, 0)
end

local function waitTankStable(timeoutSeconds, requireNonZero)
  local startTime = computer.uptime()
  local last = getTankLevel()
  local stableCount = 0

  while computer.uptime() - startTime < timeoutSeconds do
    if not leverOn() then
      return last, false, "lever off"
    end

    os.sleep(tankCheckInterval)

    local current = getTankLevel()

    if current == last then
      stableCount = stableCount + 1
    else
      stableCount = 0
      last = current
    end

    if stableCount >= tankStableSamples then
      if not requireNonZero or current > 0 then
        return current, true, "stable"
      end
    end
  end

  return last, false, "timeout"
end

local function waitTankEmpty(timeoutSeconds)
  local startTime = computer.uptime()

  while computer.uptime() - startTime < timeoutSeconds do
    if not leverOn() then
      return false, "lever off"
    end

    local level = getTankLevel()
    if level == 0 then
      return true, "empty"
    end

    os.sleep(tankCheckInterval)
  end

  return false, "timeout, level=" .. tostring(getTankLevel())
end

local function computeKeepAndRemove(sum)
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

local function collectToTank(label)
  local before = getTankLevel()

  pulse(antired)

  local level, stable, reason = waitTankStable(collectTimeout, true)

  if level <= 0 and leverOn() then
    fatalStop(
      "collect got no antimatter",
      tostring(label) ..
      ", before=" ..
      tostring(before) ..
      ", reason=" ..
      tostring(reason)
    )
  end

  if not stable and leverOn() then
    print(
      "[warn] collect not stable: label=" ..
      tostring(label) ..
      ", tank=" ..
      tostring(level) ..
      ", reason=" ..
      tostring(reason)
    )
  end

  return level, stable, reason, before
end

local function normalizeTank(label)
  local sum = getTankLevel()
  local keep, remove = computeKeepAndRemove(sum)

  if remove > 0 then
    local ok, result = pcall(tr.transferFluid, sideae, sidetp, remove)
    if not ok then
      fatalStop(
        "transferFluid failed",
        tostring(label) ..
        ", remove=" ..
        tostring(remove) ..
        ", error=" ..
        tostring(result)
      )
    end

    if result == false then
      fatalStop(
        "transferFluid returned false",
        tostring(label) ..
        ", remove=" ..
        tostring(remove)
      )
    end

    waitTankStable(outputTimeout, false)
  end

  return keep, remove
end

local function distributeToHatches(label)
  pulse(aered)

  local empty, reason = waitTankEmpty(distributeTimeout)

  if not empty and leverOn() then
    fatalStop(
      "distribution failed; tank did not empty",
      tostring(label) ..
      ", reason=" ..
      tostring(reason)
    )
  end

  return empty, reason
end

local resetCount = 0
local lastKeep = nil
local lossStreak = 0

local function rebalance(label)
  resetCount = resetCount + 1

  local collected = collectToTank(label)
  local keep, remove = normalizeTank(label)
  distributeToHatches(label)

  local deltaText = "n/a"

  if lastKeep ~= nil then
    local delta = collected - lastKeep
    deltaText = tostring(delta)

    if delta < -warnLossAmount then
      lossStreak = lossStreak + 1
      print(
        "[warn] large loss: delta=" ..
        tostring(delta) ..
        ", streak=" ..
        tostring(lossStreak) ..
        ", label=" ..
        tostring(label)
      )

      if lossStreak >= warnLossStreakLimit then
        print("[warn] continuous loss detected.")
        print("[warn] This usually means timing or distribution is wrong.")
        print("[warn] Check calibrator speed, P2P, and hatch coverage.")
      end
    else
      lossStreak = 0
    end
  end

  lastKeep = keep

  if resetCount <= 5 or resetCount % logEveryReset == 0 then
    print(
      "[rebalance] #" ..
      tostring(resetCount) ..
      ", label=" ..
      tostring(label) ..
      ", collected=" ..
      tostring(collected) ..
      ", keep=" ..
      tostring(keep) ..
      ", remove=" ..
      tostring(remove) ..
      ", delta=" ..
      deltaText
    )
  end

  return collected, keep, remove
end

local function progressInRebalanceWindow(progress)
  return (
    progress >= rebalanceProgressMin and
    progress <= rebalanceProgressMax
  )
end

local function main()
  print("[init] gt_machine=" .. tostring(gtmMachineAddress))
  print("[init] tank side=" .. sideName(sideae))
  print("[init] output side=" .. sideName(sidetp))
  print("[init] threshold=" .. tostring(threshold))
  print("[init] rebalance progress window=" ..
    tostring(rebalanceProgressMin) ..
    ".." ..
    tostring(rebalanceProgressMax)
  )

  safeRedstoneOff()
  setMachineAllowed(false)

  local wasLeverOn = false
  local lastRebalanceTime = 0

  while true do
    local on = leverOn()

    if on then
      if not wasLeverOn then
        print("[start] lever on; initial rebalance")
        setMachineAllowed(false)
        rebalance("start")
        setMachineAllowed(true)
        lastRebalanceTime = computer.uptime()
      end

      wasLeverOn = true

      local progress = getProgress()

      if progressInRebalanceWindow(progress) then
        local now = computer.uptime()

        if now - lastRebalanceTime >= rebalanceCooldown then
          rebalance("progress=" .. tostring(progress))
          lastRebalanceTime = now
        end
      end

      -- Keep the machine allowed while the lever is on.
      setMachineAllowed(true)
      os.sleep(loopSleep)
    else
      if wasLeverOn then
        print("[stop] lever off; machine disabled")
      end

      wasLeverOn = false
      setMachineAllowed(false)
      safeRedstoneOff()
      os.sleep(1)
    end
  end
end

local ok, err = pcall(main)
if not ok then
  stopAll()
  print("[fatal] " .. tostring(err))
  print("[fatal] stopped. Fix the issue, then restart the program.")
end
