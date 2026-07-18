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

-- Set these only when automatic side detection fails.
local tankSide = nil
local outputSide = nil

local threshold = 7615776
local takeProgress = 2
local cycleTicks = 20
local putTick = 16
local putProgress = putTick + 1
local abnormalLoss = threshold / 300
local tankWaitTimeout = 5
local stopWaitTimeout = 3
local transferRetryDelay = 1
local printEvery = 1

local allSides = {
  sides.down,
  sides.up,
  sides.north,
  sides.south,
  sides.west,
  sides.east,
}

local sideNames = {
  [sides.down] = "down",
  [sides.up] = "up",
  [sides.north] = "north",
  [sides.south] = "south",
  [sides.west] = "west",
  [sides.east] = "east",
}

local forge = nil
local tank = nil
local controlSides = nil
local stopReason = "unknown"
local cycle = 0
local lastKeep = nil
local totalGain = 0
local totalInput = 0

local function sideName(side)
  local name = sideNames[side] or "unknown"
  return name .. "(" .. tostring(side) .. ")"
end

local function pad(value, width)
  local text = tostring(value)
  return string.rep(" ", math.max(0, width - #text)) .. text
end

local function call(addr, method, ...)
  local ok, value = pcall(component.invoke, addr, method, ...)
  if not ok then
    local msg = method .. " failed on " .. tostring(addr)
    error(msg .. ": " .. tostring(value))
  end
  return value
end

local function requireMethods(addr, label, names)
  local methods = component.methods(addr) or {}
  for _, name in ipairs(names) do
    if methods[name] == nil then
      error(label .. " missing method: " .. name)
    end
  end
end

local function safeTankValue(method, side)
  local ok, value = pcall(method, side)
  return ok and (tonumber(value) or 0) or 0
end

local function fluidSide(side)
  local level = safeTankValue(trans.getTankLevel, side)
  local capacity = safeTankValue(trans.getTankCapacity, side)
  local ok, info = pcall(trans.getTankInfo, side)
  local hasInfo = ok and type(info) == "table" and next(info) ~= nil
  if level == 0 and capacity == 0 and not hasInfo then
    return nil
  end
  return {side = side, level = level, capacity = capacity}
end

local function fluidSides()
  local found = {}
  for _, side in ipairs(allSides) do
    local item = fluidSide(side)
    if item then
      found[#found + 1] = item
    end
  end
  return found
end

local function uniqueMaxCapacity(items)
  local best = nil
  local tied = false
  for _, item in ipairs(items) do
    if not best or item.capacity > best.capacity then
      best = item
      tied = false
    elseif item.capacity == best.capacity then
      tied = true
    end
  end
  return best and not tied and best.side or nil
end

local function detectFluidSides()
  local found = fluidSides()
  if not tankSide then
    local nonempty = {}
    for _, item in ipairs(found) do
      if item.level > 0 then
        nonempty[#nonempty + 1] = item
      end
    end
    if #nonempty == 1 then
      tankSide = nonempty[1].side
    else
      tankSide = uniqueMaxCapacity(found)
    end
  end
  if not tankSide then
    error("cannot detect quantum tank side; set tankSide")
  end

  if not outputSide then
    local outputs = {}
    for _, item in ipairs(found) do
      if item.side ~= tankSide then
        outputs[#outputs + 1] = item.side
      end
    end
    if #outputs == 1 then
      outputSide = outputs[1]
    end
  end
  if not outputSide then
    error("cannot detect output side; set outputSide")
  end

  print("[init] tank side=" .. sideName(tankSide))
  print("[init] output side=" .. sideName(outputSide))
end

local function isTankName(name)
  name = string.lower(tostring(name))
  local plain = true
  return string.find(name, "quantum", 1, plain)
    or string.find(name, "tank", 1, plain)
    or string.find(name, "super", 1, plain)
end

local function detectMachines()
  local others = {}
  local tankMatches = {}

  for addr in component.list("gt_machine") do
    local name = tostring(call(addr, "getName"))
    local item = {addr = addr, name = name}
    if name == "antimatterForge" then
      if forge then
        error("multiple antimatterForge components")
      end
      forge = addr
    else
      others[#others + 1] = item
      if isTankName(name) then
        tankMatches[#tankMatches + 1] = item
      end
    end
  end

  if not forge then
    error("cannot find antimatterForge")
  end
  if #tankMatches == 1 then
    tank = tankMatches[1].addr
  elseif #tankMatches == 0 and #others == 1 then
    tank = others[1].addr
  else
    error("cannot find unique quantum tank machine")
  end

  requireMethods(forge, "forge", {
    "setWorkAllowed",
    "isWorkAllowed",
    "getWorkProgress",
  })
  requireMethods(tank, "tank", {"setWorkAllowed"})
  print("[init] forge=" .. tostring(forge))
  print("[init] tank=" .. tostring(call(tank, "getName")))
end

local function setForge(value)
  call(forge, "setWorkAllowed", value)
end

local function setTank(value)
  call(tank, "setWorkAllowed", value)
end

local function forgeAllowed()
  return not not call(forge, "isWorkAllowed")
end

local function progress()
  return tonumber(call(forge, "getWorkProgress")) or 0
end

local function tankLevel()
  return safeTankValue(trans.getTankLevel, tankSide)
end

local function detectControls()
  local active = {}
  for _, side in ipairs(allSides) do
    if rs.getInput(side) > 0 then
      active[#active + 1] = side
    end
  end
  if #active < 2 then
    return false
  end
  if #active > 2 then
    error("expected exactly two redstone inputs")
  end
  controlSides = active
  local names = sideName(active[1]) .. " + " .. sideName(active[2])
  print("[init] control sides=" .. names)
  return true
end

local function controlsOn()
  if not controlSides and not detectControls() then
    return false
  end
  return rs.getInput(controlSides[1]) > 0
    and rs.getInput(controlSides[2]) > 0
end

local function forceStop()
  pcall(setForge, false)
  pcall(setTank, false)
end

local function safeStop()
  pcall(setForge, false)
  local started = computer.uptime()
  while progress() == 1 do
    if computer.uptime() - started > stopWaitTimeout then
      print("[warn] timeout waiting safe tick before tank stop")
      break
    end
    os.sleep(0)
  end
  pcall(setTank, false)
end

local function confirmForgeStopped()
  local samples = 0
  while samples < 2 do
    setForge(false)
    if not forgeAllowed() and progress() == 0 then
      samples = samples + 1
    else
      samples = 0
    end
    os.sleep(0.05)
  end
  print("[recover] forge stop confirmed")
end

local function waitTankPositive(timeout)
  local started = computer.uptime()
  while controlsOn() do
    local amount = tankLevel()
    if amount > 0 then
      return amount
    end
    if timeout and computer.uptime() - started > timeout then
      return nil
    end
    os.sleep(0)
  end
  return nil
end

local function waitTankEmpty()
  while controlsOn() do
    if tankLevel() == 0 then
      return true
    end
    os.sleep(0)
  end
  return false
end

local function waitProgressAtLeast(target)
  while controlsOn() do
    local value = progress()
    if value >= target then
      return value, true
    end
    if value < takeProgress then
      return value, false
    end
    os.sleep(0)
  end
  return nil, false
end

local function waitProgressBelow(target)
  while controlsOn() do
    local value = progress()
    if value < target then
      return value
    end
    os.sleep(0)
  end
  return nil
end

local function waitForgeStart()
  while controlsOn() do
    local value = progress()
    if value >= takeProgress then
      return value
    end
    os.sleep(0)
  end
  return nil
end

local function splitAmount(sum)
  local keep = sum > threshold and threshold or sum - sum % 16
  return math.max(0, keep), sum - math.max(0, keep)
end

local function tryTransfer(sum)
  local keep, remove = splitAmount(sum)
  if remove == 0 then
    return true, keep, remove
  end

  local ok, result, moved = pcall(
    trans.transferFluid,
    tankSide,
    outputSide,
    remove
  )
  local remaining = tankLevel()
  if ok and result ~= false and remaining <= keep then
    return true, keep, remove
  end
  return false, keep, remove, result, moved, remaining
end

local function recoverTransfer()
  print("[recover] transfer failed; stopping forge")
  confirmForgeStopped()
  setTank(false)

  local sum = waitTankPositive(nil)
  if not sum then
    stopReason = "control off during transfer recovery"
    return nil, nil, false
  end
  print("[recover] antimatter returned amount=" .. tostring(sum))

  while true do
    sum = tankLevel()
    local ok, keep, remove, result, moved, left = tryTransfer(sum)
    if ok then
      local msg = "[recover] transfer succeeded remove="
      print(msg .. tostring(remove) .. " keep=" .. tostring(keep))
      if not controlsOn() then
        stopReason = "control off after transfer recovery"
        return keep, remove, false
      end
      setTank(true)
      if not waitTankEmpty() then
        stopReason = "control off during recovery restart"
        return keep, remove, false
      end
      setForge(true)
      print("[recover] forge restarted")
      return keep, remove, true
    end

    local msg = "[recover] retry remove=" .. tostring(remove)
    msg = msg .. " result=" .. tostring(result)
    msg = msg .. " moved=" .. tostring(moved)
    print(msg .. " tank=" .. tostring(left))
    os.sleep(transferRetryDelay)
  end
end

local function transferExcess(sum)
  local ok, keep, remove, result, moved, left = tryTransfer(sum)
  if ok then
    return keep, remove, false, true
  end

  local msg = "[bad] transfer failed remove=" .. tostring(remove)
  msg = msg .. " result=" .. tostring(result)
  msg = msg .. " moved=" .. tostring(moved)
  print(msg .. " tank=" .. tostring(left))
  keep, remove, ok = recoverTransfer()
  return keep, remove, true, ok
end

local function failTankWait()
  print("[bad] timeout/control off waiting for tank")
  print("[bad] side=" .. sideName(tankSide))
  print("[bad] level=" .. tostring(tankLevel()))
  stopReason = "tank wait failed"
end

local function primeFirstCycle()
  setForge(false)
  setTank(false)
  local sum = waitTankPositive(tankWaitTimeout)
  if not sum then
    failTankWait()
    return nil
  end

  local keep, _, recovered, restarted = transferExcess(sum)
  if not keep or recovered and not restarted then
    return nil
  end
  if recovered then
    return keep
  end

  local start = progress()
  if start >= takeProgress and start < putProgress then
    local hit
    start, hit = waitProgressAtLeast(putProgress)
    if not start or not hit then
      setForge(false)
      stopReason = "missed initial put window"
      return nil
    end
  end

  setTank(true)
  if not waitTankEmpty() then
    stopReason = "control off while priming tank"
    return nil
  end
  setForge(true)
  return keep
end

local function printCycle(data)
  if cycle % printEvery ~= 0 then
    return
  end
  local width = math.max(8, #tostring(threshold) + 2)
  local deltaWidth = math.max(6, width - 2)
  local average = totalInput > 0 and totalGain / totalInput or 0
  local msg = "[cyc] #" .. pad(cycle, 4)
  msg = msg .. " " .. pad(data.sum, width)
  msg = msg .. " - " .. pad(data.remove, width)
  msg = msg .. " = " .. pad(data.keep, width)
  msg = msg .. ", inc=" .. pad(data.gain, deltaWidth)
  msg = msg .. string.format(", ave=%6.2f%%", average * 100)
  msg = msg .. ", take " .. data.takeStart .. "-" .. data.takeEnd
  msg = msg .. " | put " .. data.putStart .. "-" .. data.putEnd
  print(msg)
end

local function runCycle(first)
  if first then
    lastKeep = primeFirstCycle()
    if not lastKeep then
      return false
    end
  elseif not waitProgressBelow(takeProgress) then
    stopReason = "control off before next cycle"
    return false
  end

  local takeStart = waitForgeStart()
  if not takeStart then
    stopReason = "control off before take window"
    return false
  end
  cycle = cycle + 1
  setTank(false)

  local sum = waitTankPositive(nil)
  if not sum then
    failTankWait()
    return false
  end
  if lastKeep and sum < lastKeep - abnormalLoss then
    local loss = lastKeep - sum
    print("[bad] abnormal antimatter loss=" .. tostring(loss))
    setForge(false)
    stopReason = "abnormal antimatter loss"
    return false
  end

  local keep, remove, recovered, restarted = transferExcess(sum)
  if not keep or recovered and not restarted then
    return false
  end
  if recovered then
    lastKeep = keep
    stopReason = "ok"
    return true
  end
  local takeEnd = progress()

  local putStart, hit = waitProgressAtLeast(putProgress)
  if not putStart or not hit then
    setForge(false)
    stopReason = "missed put window/control off"
    return false
  end
  setTank(true)
  local emptied = waitTankEmpty()
  local putEnd = progress()
  if not emptied then
    stopReason = "control off while emptying tank"
    return false
  end

  local gain = lastKeep and sum - lastKeep or 0
  if lastKeep then
    totalGain = totalGain + gain
    totalInput = totalInput + lastKeep
  end
  printCycle({
    sum = sum,
    remove = remove,
    keep = keep,
    gain = gain,
    takeStart = takeStart,
    takeEnd = takeEnd,
    putStart = putStart,
    putEnd = putEnd,
  })
  lastKeep = keep
  stopReason = "ok"
  return true
end

local function main()
  detectMachines()
  detectFluidSides()
  print("[init] threshold=" .. tostring(threshold))
  local timing = "[init] take>=" .. takeProgress
  timing = timing .. ", put_tick=" .. putTick
  timing = timing .. ", put_progress>=" .. putProgress
  timing = timing .. ", safe_ticks=" .. cycleTicks - putProgress
  print(timing)
  print("[init] waiting for two redstone inputs")

  while true do
    if controlsOn() then
      print("[start] both signals on")
      local first = true
      while controlsOn() do
        local ok = runCycle(first)
        first = false
        if not ok then
          break
        end
      end
      print("[stop] " .. stopReason)
    end
    safeStop()
    os.sleep(1)
  end
end

local ok, err = pcall(main)
if not ok then
  forceStop()
  print("[fatal] " .. tostring(err))
end
