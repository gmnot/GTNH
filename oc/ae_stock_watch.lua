local component = require("component")
local computer = require("computer")
local os = require("os")
local term = require("term")

-- Fill these yourself.
-- Item config fields:
--   name: registry name, optional if label is set
--   label: display name, optional if name is set
--   damage: optional metadata/damage filter
--   min: required amount, supports k/m/g/t suffix
local ITEM_CONFIGS = {
  { name = "gtnhintergalactic:item.DysonSwarmParts", damage = 0, min = "1k" },
}

-- Fluid config fields:
--   name: fluid registry name
--   label: optional display name
--   min: required amount in mB, supports k/m/g/t suffix
local FLUID_CONFIGS = {
  { name = "magmadah based liquid fuel mkvi", min = "10k" },
  { name = "molten.infinity", min = "500m" },
  { name = "temporalfluid", aliases = { "temporalFluid" }, min = "1m" },
  { name = "excitedtec", min = "500m" },
}

local CHECK_INTERVAL = 5
local DISPLAY_WIDTH = 80
local DISPLAY_HEIGHT = 25

local gpu = component.isAvailable("gpu") and component.gpu or nil
local meInterface = nil
local meAddress = nil

local suffixMultipliers = { k = 1e3, m = 1e6, g = 1e9, t = 1e12 }

local function parseNumber(value)
  if type(value) == "number" then
    return value
  end

  local text = tostring(value or ""):lower()
  local numPart, suffix = text:match("^%s*([%d%.]+)%s*([kmgt]?)%s*$")
  local number = tonumber(numPart)
  if number == nil then
    error("invalid amount: " .. tostring(value))
  end

  return number * (suffixMultipliers[suffix] or 1)
end

local function formatNumber(value)
  local number = tonumber(value) or 0
  for _, unit in ipairs({ { "t", 1e12 }, { "g", 1e9 }, { "m", 1e6 }, { "k", 1e3 } }) do
    if math.abs(number) >= unit[2] then
      return string.format("%.1f%s", number / unit[2], unit[1])
    end
  end
  return tostring(math.floor(number))
end

local function charInfo(text, index)
  local byte = text:byte(index)
  if byte == nil then return 0, 0 end
  if byte < 0x80 then return 1, 1 end
  if byte < 0xE0 then return 2, 2 end
  if byte < 0xF0 then return 3, 2 end
  return 4, 2
end

local function textWidth(text)
  local width = 0
  local i = 1
  text = tostring(text)
  while i <= #text do
    local len, charWidth = charInfo(text, i)
    width = width + charWidth
    i = i + len
  end
  return width
end

local function fitText(text, maxWidth)
  local result = ""
  local width = 0
  local i = 1
  text = tostring(text)

  while i <= #text do
    local len, charWidth = charInfo(text, i)
    if width + charWidth > maxWidth then
      return result
    end
    result = result .. text:sub(i, i + len - 1)
    width = width + charWidth
    i = i + len
  end

  return result
end

local function padRight(text, width)
  text = tostring(text)
  local padding = width - textWidth(text)
  if padding <= 0 then
    return fitText(text, width)
  end
  return text .. string.rep(" ", padding)
end

local function safeCall(fn, ...)
  local ok, result = pcall(fn, ...)
  if ok then
    return result
  end
  return nil
end

local function hasMethod(addr, name)
  local methods = safeCall(component.methods, addr)
  return methods ~= nil and methods[name] ~= nil
end

local function initDisplay()
  if gpu ~= nil then
    pcall(gpu.setViewport, DISPLAY_WIDTH, DISPLAY_HEIGHT)
    pcall(gpu.setForeground, 0x00FF00)
  end
end

local function clearScreen()
  if gpu ~= nil then
    gpu.fill(1, 1, DISPLAY_WIDTH, DISPLAY_HEIGHT, " ")
  end
  term.clear()
  term.setCursor(1, 1)
end

local function drawLines(lines)
  clearScreen()
  for row = 1, DISPLAY_HEIGHT do
    local line = fitText(lines[row] or "", DISPLAY_WIDTH)
    if gpu ~= nil then
      gpu.set(1, row, padRight(line, DISPLAY_WIDTH))
    else
      io.write(line .. "\n")
    end
  end
end

local function initMeInterface()
  if not component.isAvailable("me_interface") then
    error("no me_interface component")
  end

  local candidates = {}
  for addr in component.list("me_interface", true) do
    local itemMethods = hasMethod(addr, "getItemsInNetwork")
    local fluidMethods = hasMethod(addr, "getFluidsInNetwork")
    table.insert(candidates, {
      address = addr,
      items = itemMethods,
      fluids = fluidMethods,
    })

    if itemMethods and fluidMethods then
      meAddress = addr
      meInterface = component.proxy(addr)
      return
    end
  end

  clearScreen()
  print("No usable me_interface found.")
  for i, item in ipairs(candidates) do
    print(string.format(
      "[%d] %s items=%s fluids=%s",
      i,
      tostring(item.address),
      tostring(item.items),
      tostring(item.fluids)
    ))
  end
  error("me_interface missing getItemsInNetwork/getFluidsInNetwork")
end

local function normalizeConfigs()
  for _, config in ipairs(ITEM_CONFIGS) do
    config.min = parseNumber(config.min)
  end

  for _, config in ipairs(FLUID_CONFIGS) do
    config.min = parseNumber(config.min)
  end
end

local function displayName(config)
  return config.label or config.name or "unknown"
end

local function itemMatches(stack, config)
  if config.name ~= nil and config.name ~= "" and stack.name ~= config.name then
    return false
  end
  if config.label ~= nil and config.label ~= "" and stack.label ~= config.label then
    return false
  end
  if config.damage ~= nil and tonumber(stack.damage) ~= tonumber(config.damage) then
    return false
  end
  return true
end

local function getItemQuery(config)
  local query = {}
  if config.name ~= nil and config.name ~= "" then
    query.name = config.name
  end
  return query
end

local function getItemAmount(config)
  local total = 0
  local items = safeCall(meInterface.getItemsInNetwork, getItemQuery(config)) or {}

  for _, stack in ipairs(items or {}) do
    if type(stack) == "table" and itemMatches(stack, config) then
      total = total + (tonumber(stack.size or stack.amount) or 0)
    end
  end

  return total
end

local function fluidNameMatches(name, target)
  if name == nil or target == nil then
    return false
  end
  return tostring(name):lower() == tostring(target):lower()
end

local function fluidMatches(fluid, config)
  if fluidNameMatches(fluid.name, config.name) then
    return true
  end

  for _, alias in ipairs(config.aliases or {}) do
    if fluidNameMatches(fluid.name, alias) then
      return true
    end
  end

  return false
end

local function addFluidQueryNames(names, config)
  if config.name ~= nil and config.name ~= "" then
    table.insert(names, config.name)
  end
  for _, alias in ipairs(config.aliases or {}) do
    if alias ~= nil and alias ~= "" then
      table.insert(names, alias)
    end
  end
end

local function getFluidAmount(config)
  local total = 0
  local names = {}
  local seen = {}
  addFluidQueryNames(names, config)

  for _, name in ipairs(names) do
    local fluids = safeCall(meInterface.getFluidsInNetwork, { name = name }) or {}
    for _, fluid in ipairs(fluids or {}) do
      if type(fluid) == "table" and fluidMatches(fluid, config) then
        local key = tostring(fluid.name or name):lower()
        if not seen[key] then
          seen[key] = true
          total = total + (tonumber(fluid.amount) or 0)
        end
      end
    end
  end

  return total
end

local function addStatusLine(lines, kind, name, current, target)
  table.insert(lines, string.format(
    "%-5s %-34s %10s / %-10s lack %s",
    kind,
    fitText(name, 34),
    formatNumber(current),
    formatNumber(target),
    formatNumber(target - current)
  ))
end

local function buildScreen()
  local lines = {}
  local missing = 0

  table.insert(lines, "AE Stock Watch")
  table.insert(lines, "Interface: " .. tostring(meAddress))
  table.insert(lines, string.format(
    "Items cfg:%d  Fluids cfg:%d  Uptime:%ds",
    #ITEM_CONFIGS,
    #FLUID_CONFIGS,
    math.floor(computer.uptime())
  ))
  table.insert(lines, string.rep("-", DISPLAY_WIDTH))

  if #ITEM_CONFIGS == 0 and #FLUID_CONFIGS == 0 then
    table.insert(lines, "No configs yet. Fill ITEM_CONFIGS and FLUID_CONFIGS at top of file.")
  else
    for _, config in ipairs(ITEM_CONFIGS) do
      local current = getItemAmount(config)
      if current < config.min then
        missing = missing + 1
        addStatusLine(lines, "ITEM", displayName(config), current, config.min)
      end
    end

    for _, config in ipairs(FLUID_CONFIGS) do
      local current = getFluidAmount(config)
      if current < config.min then
        missing = missing + 1
        addStatusLine(lines, "FLUID", displayName(config), current, config.min)
      end
    end

    if missing == 0 then
      table.insert(lines, "All configured items and fluids are enough.")
    else
      table.insert(lines, "")
      table.insert(lines, "Missing entries: " .. tostring(missing))
    end
  end

  table.insert(lines, "")
  table.insert(lines, "Refresh: " .. tostring(CHECK_INTERVAL) .. "s")
  return lines
end

local function main()
  initDisplay()
  normalizeConfigs()
  initMeInterface()

  while true do
    drawLines(buildScreen())
    if type(collectgarbage) == "function" then
      collectgarbage()
    end
    os.sleep(CHECK_INTERVAL)
  end
end

local ok, err = pcall(main)
if not ok then
  clearScreen()
  print("[fatal] " .. tostring(err))
end
