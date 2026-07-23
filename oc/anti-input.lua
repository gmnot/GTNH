local component = require("component")
local os = require("os")
local sides = require("sides")

if not component.isAvailable("redstone") then
  error("no redstone component")
end

-- Change this to the side connected to anti.lua's redstone input.
local outputSide = sides.north
local outputStrength = 15
local checkInterval = 3

-- keep in sync with anti.lua
-- local threshold = 8015776   -- eternity
local threshold = 40160576  -- blue
local inputFluids = {
  "temporalfluid",
  "molten.eternity",
  "molten.shirabon",
  "naquadah based liquid fuel mkvi (depleted)",
  "protomatter",
  "molten.magnetohydrodynamicallyconstrainedstarmatter",
}

local fluidShortNames = {
  ["temporalfluid"] = "Time",
  ["molten.eternity"] = "Eter",
  ["molten.shirabon"] = "Shira",
  ["naquadah based liquid fuel mkvi (depleted)"] = "NqVI-D",
  ["protomatter"] = "Proto",
  ["molten.magnetohydrodynamicallyconstrainedstarmatter"] = "blue",
}

local n_machine = 6

-- Fluid use per machine and operation, as shown in the recipe:
-- antimatter_amount ^ exponent (L). One operation runs per second.
local fluidExponents = {
  ["temporalfluid"] = 1 / 2,
  ["molten.eternity"] = 1 / 2,
  ["molten.shirabon"] = 2 / 7,
  ["naquadah based liquid fuel mkvi (depleted)"] = 1 / 3,
  ["protomatter"] = 1 / 2,
  ["molten.magnetohydrodynamicallyconstrainedstarmatter"] = 2 / 7,
}

local function fluidMinimumsFor(seconds)
  local minimums = {}
  for _, fluidName in ipairs(inputFluids) do
    local exponent = fluidExponents[fluidName]
    minimums[fluidName] = n_machine
      * threshold ^ exponent
      * seconds
  end
  return minimums
end

local inputFluidStopMins = fluidMinimumsFor(30)
local inputFluidStartMins = fluidMinimumsFor(300)

local rs = component.redstone
local meInterface = nil
local lastStatusKey = nil

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

local function initMeInterface()
  if not component.isAvailable("me_interface") then
    error("no me_interface component")
  end

  for addr in component.list("me_interface", true) do
    local methods = component.methods(addr)
    if methods ~= nil and methods.getFluidsInNetwork ~= nil then
      meInterface = component.proxy(addr)
      print("[init] me_interface=" .. tostring(addr))
      return
    end
  end

  error("me_interface missing method: getFluidsInNetwork")
end

-- This intentionally uses the same network read and name mapping as anti.lua.
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

local function allInputsAbove(amounts, minimums)
  for _, fluidName in ipairs(inputFluids) do
    local minAmount = minimums[fluidName]
    if (amounts[fluidName] or 0) <= minAmount then
      return false, fluidName, amounts[fluidName] or 0
    end
  end

  return true
end

local function formatAmount(value)
  local number = tonumber(value) or 0
  for _, unit in ipairs({ { "t", 1e12 }, { "g", 1e9 }, { "m", 1e6 }, { "k", 1e3 } }) do
    if math.abs(number) >= unit[2] then
      return string.format("%.0f%s", number / unit[2], unit[1])
    end
  end
  return tostring(math.floor(number))
end

local function padRight(value, width)
  local text = tostring(value)
  return text .. string.rep(" ", math.max(0, width - #text))
end

local function shortFluidName(fluidName)
  return fluidShortNames[fluidName] or fluidName
end

local function printAmounts(amounts, targetAmounts)
  local values = {}
  local nameWidth = 0
  local amountWidth = 0
  local targetWidth = 0

  for _, fluidName in ipairs(inputFluids) do
    nameWidth = math.max(nameWidth, #shortFluidName(fluidName))
    amountWidth = math.max(amountWidth, #formatAmount(amounts[fluidName] or 0))
    targetWidth = math.max(targetWidth, #formatAmount(targetAmounts[fluidName]))
  end

  for _, fluidName in ipairs(inputFluids) do
    local name = padRight(shortFluidName(fluidName), nameWidth)
    local current = formatAmount(amounts[fluidName] or 0)
    local targetText = formatAmount(targetAmounts[fluidName])
    current = string.rep(" ", amountWidth - #current) .. current
    targetText = string.rep(" ", targetWidth - #targetText) .. targetText
    table.insert(values, name .. " " .. current .. "/" .. targetText)
  end

  print("[check] " .. table.concat(values, " || "))
end

local function setOutput(enabled)
  rs.setOutput(outputSide, enabled and outputStrength or 0)
end

local function printState(statusKey, enabled, reason, fluidName, amount, minAmount)
  if statusKey == lastStatusKey then
    return
  end
  lastStatusKey = statusKey

  local message = enabled and "[on] inputs ready" or "[off] inputs low"
  message = message .. " reason=" .. tostring(reason)

  if fluidName ~= nil then
    message = message ..
      " fluid=" .. shortFluidName(fluidName) ..
      " amount=" .. formatAmount(amount) ..
      "/" .. formatAmount(minAmount)
  end

  print(message)
end

local function main()
  setOutput(false)
  initMeInterface()

  print("[init] output side=" .. sideName(outputSide))
  print("[init] stop mins cover 10 seconds of recipe consumption")
  print("[init] start mins cover 300 seconds of recipe consumption")
  print("[init] output starts off; all inputs must reach start min")

  local enabled = false

  while true do
    local readOk, amounts = pcall(getNetworkFluidAmounts)

    if not readOk then
      if enabled then
        enabled = false
        setOutput(false)
      end
      printState("read failed", false, "network read failed: " .. tostring(amounts))
    else
      local targetAmounts = enabled and inputFluidStopMins or inputFluidStartMins
      printAmounts(amounts, targetAmounts)
    end

    if readOk and enabled then
      local enough, fluidName, amount = allInputsAbove(amounts, inputFluidStopMins)
      if not enough then
        enabled = false
        setOutput(false)
        printState("stop:" .. fluidName, false, "stop min", fluidName, amount, inputFluidStopMins[fluidName])
      end
    elseif readOk then
      local enough, fluidName, amount = allInputsAbove(amounts, inputFluidStartMins)
      if enough then
        enabled = true
        setOutput(true)
        printState("on", true, "start min")
      else
        printState(
          "wait:" .. fluidName,
          false,
          "waiting for start min",
          fluidName,
          amount,
          inputFluidStartMins[fluidName]
        )
      end
    end

    os.sleep(checkInterval)
  end
end

local ok, err = pcall(main)
if not ok then
  pcall(setOutput, false)
  print("[fatal] " .. tostring(err))
end
