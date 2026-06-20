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

-- Timing parameters.
local pulseSeconds = 0.05
local tankCheckInterval = 0.20
local tankStableSamples = 3
local collectTimeout = 8
local normalizeTimeout = 8
local distributeTimeout = 8
local machineStartTimeout = 20
local progressCheckInterval = 0.05

-- Treat progress >= this value as "machine is working".
-- If the machine starts and finishes too fast to detect, change this to 1.
local activeProgressMin = 1

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

local function die(message)
  io.stderr:write("[fatal] " .. message .. "\n")
  os.exit(1)
end

local function invoke(address, methodName, ...)
  local ok, result = pcall(component.invoke, address, methodName, ...)
  if not ok then
    die(
      tostring(methodName) ..
      " failed on " ..
      tostring(address) ..
      ": " ..
      tostring(result)
    )
  end
  return result
end

local function tryInvoke(address, methodName, ...)
  local ok, result = pcall(component.invoke, address, methodName, ...)
  if not ok then
    return false, result
  end
  return true, result
end

local function findMachineAddress()
  if machineAddress ~= nil and machineAddress ~= "" then
    return machineAddress
  end

  local candidates = {}

  for address in component.list("gt_machine") do
    local ok, name = tryInvoke(address, "getName")
    if ok and tostring(name) == "antimatterForge" then
      return address
    end

    table.insert(candidates, {
      address = address,
      name = ok and tostring(name) or "unknown",
    })
  end

  if #candidates == 0 then
    die("no gt_machine component found")
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

  die("set machineAddress manually")
end

local gtmMachineAddress = findMachineAddress()

local function setMachineAllowed(allowed)
  invoke(gtmMachineAddress, "setWorkAllowed", allowed)
end

local function getProgress()
  local progress = invoke(gtmMachineAddress, "getWorkProgress")
  return tonumber(progress) or 0
end

local function leverOn()
  return trig.getInput(trigside) > 0
end

local function getTankLevel()
  return tonumber(tr.getTankLevel(sideae)) or 0
end

local function pulse(redstoneComp, side)
  redstoneComp.setOutput(side, 15)
  os.sleep(pulseSeconds)
  redstoneComp.setOutput(side, 0)
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

local function computeRemoveAmount(sum)
  local keep

  if sum > threshold then
    keep = threshold
  else
    keep = sum - (sum % 16)
  end

  if keep < 0 then
    keep = 0
  end

  return sum - keep, keep
end

local function collectToTank()
  print("[collect] pulse antimatter hatches")
  pulse(antired, sidered)

  local level, ok, reason = waitTankStable(collectTimeout, true)

  print(
    "[collect] tank=" ..
    tostring(level) ..
    ", stable=" ..
    tostring(ok) ..
    ", reason=" ..
    tostring(reason)
  )

  return level, ok
end

local function normalizeTank()
  local sum = getTankLevel()
  local remove, keep = computeRemoveAmount(sum)

  print(
    "[normalize] total=" ..
    tostring(sum) ..
    ", keep=" ..
    tostring(keep) ..
    ", remove=" ..
    tostring(remove)
  )

  if remove <= 0 then
    return true
  end

  local ok, result = pcall(tr.transferFluid, sideae, sidetp, remove)
  if not ok then
    print("[warn] transferFluid error: " .. tostring(result))
    return false
  end

  if result == false then
    print("[warn] transferFluid returned false")
    return false
  end

  local level, stable, reason = waitTankStable(normalizeTimeout, false)

  print(
    "[normalize] after output tank=" ..
    tostring(level) ..
    ", stable=" ..
    tostring(stable) ..
    ", reason=" ..
    tostring(reason)
  )

  return stable
end

local function distributeToHatches()
  print("[distribute] pulse quantum tank")
  pulse(aered, sidered)

  local ok, reason = waitTankEmpty(distributeTimeout)

  print(
    "[distribute] empty=" ..
    tostring(ok) ..
    ", reason=" ..
    tostring(reason)
  )

  return ok
end

local function waitMachineStart()
  local startTime = computer.uptime()

  while computer.uptime() - startTime < machineStartTimeout do
    if not leverOn() then
      return false, "lever off"
    end

    local progress = getProgress()

    if progress >= activeProgressMin then
      print("[machine] started, progress=" .. tostring(progress))
      return true, "started"
    end

    os.sleep(progressCheckInterval)
  end

  return false, "start timeout, progress=" .. tostring(getProgress())
end

local function waitMachineDone()
  local doneSamples = 0
  local requiredDoneSamples = 5

  while true do
    if not leverOn() then
      return false, "lever off"
    end

    local progress = getProgress()
    if progress < activeProgressMin then
      doneSamples = doneSamples + 1
      if doneSamples >= requiredDoneSamples then
        print("[machine] done, progress=" .. tostring(progress))
        return true, "done"
      end
    else
      doneSamples = 0
    end

    os.sleep(progressCheckInterval)
  end
end

local function runCycle()
  setMachineAllowed(false)

  local _, collected = collectToTank()
  if not collected then
    print("[cycle] collect failed, keep machine off")
    setMachineAllowed(false)
    return false
  end

  if not normalizeTank() then
    print("[cycle] normalize failed, keep machine off")
    setMachineAllowed(false)
    return false
  end

  if not distributeToHatches() then
    print("[cycle] distribute failed, keep machine off")
    setMachineAllowed(false)
    return false
  end

  setMachineAllowed(true)

  local started, startReason = waitMachineStart()
  if not started then
    print("[cycle] machine did not start: " .. tostring(startReason))
    setMachineAllowed(false)
    return false
  end

  local done, doneReason = waitMachineDone()
  if not done then
    print("[cycle] machine stopped waiting: " .. tostring(doneReason))
    setMachineAllowed(false)
    return false
  end

  return true
end

local function main()
  print("[init] gt_machine=" .. tostring(gtmMachineAddress))
  print("[init] tank side=" .. sideName(sideae))
  print("[init] output side=" .. sideName(sidetp))
  print("[init] threshold=" .. tostring(threshold))

  antired.setOutput(sidered, 0)
  aered.setOutput(sidered, 0)
  setMachineAllowed(false)

  while true do
    if leverOn() then
      runCycle()
      os.sleep(0)
    else
      setMachineAllowed(false)
      os.sleep(2)
    end
  end
end

main()