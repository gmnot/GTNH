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

local threshold = 7615776  -- keep in sync with anti.lua

local inputFluids = {
  "temporalfluid",
  "molten.eternity",
  "molten.shirabon",
  "naquadah based liquid fuel mkvi (depleted)",
  "protomatter",
}

local n_machine = 2
local n_per_sec = n_machine * math.sqrt(threshold)
local inputFluidStopMin = n_per_sec * 10
local inputFluidStartMin = n_per_sec * 300

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

local function allInputsAbove(amounts, minAmount)
  for _, fluidName in ipairs(inputFluids) do
    if (amounts[fluidName] or 0) <= minAmount then
      return false, fluidName, amounts[fluidName] or 0
    end
  end

  return true
end

local function printAmounts(amounts)
  local values = {}

  for _, fluidName in ipairs(inputFluids) do
    table.insert(
      values,
      fluidName .. "=" .. tostring(amounts[fluidName] or 0)
    )
  end

  print("[check] " .. table.concat(values, ", "))
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
      " fluid=" .. tostring(fluidName) ..
      " amount=" .. tostring(amount) ..
      " need>" .. string.format("%.2f", minAmount)
  end

  print(message)
end

local function main()
  setOutput(false)
  initMeInterface()

  print("[init] output side=" .. sideName(outputSide))
  print("[init] stop min=" .. string.format("%.2f", inputFluidStopMin))
  print("[init] start min=" .. string.format("%.2f", inputFluidStartMin))
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
      printAmounts(amounts)
    end

    if readOk and enabled then
      local enough, fluidName, amount = allInputsAbove(amounts, inputFluidStopMin)
      if not enough then
        enabled = false
        setOutput(false)
        printState("stop:" .. fluidName, false, "stop min", fluidName, amount, inputFluidStopMin)
      end
    elseif readOk then
      local enough, fluidName, amount = allInputsAbove(amounts, inputFluidStartMin)
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
          inputFluidStartMin
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
