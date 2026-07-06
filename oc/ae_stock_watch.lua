local component = require("component")
local computer = require("computer")
local os = require("os")
local term = require("term")

-- Fill these yourself.
-- Item config fields:
--   name: registry name, optional if label is set
--   label: display name, optional if name is set
--   damage: optional metadata/damage filter
--   short: display name
--   fatal/warn: thresholds, supports k/m/g/t suffix
local ITEM_CONFIGS = {
  { name = "gtnhintergalactic:item.DysonSwarmParts", damage = 0, short = "Dyson", fatal = "500", warn = "1k" },
}

-- Fluid config fields:
--   name: fluid registry name
--   label: optional display name
--   short: display name
--   fatal/warn: required amount in mB, supports k/m/g/t suffix
local FLUID_CONFIGS = {
  { name = "naquadah based liquid fuel mkvi", short = "NqFuel VI", fatal = "10k", warn = "300k" },
  { name = "molten.infinity", short = "Inf", fatal = "500m", warn = "2g" },
  { name = "temporalfluid", short = "Time", fatal = "200k", warn = "1m" },
  { name = "exciteddtrc", short = "cat 异星", fatal = "150m", warn = "500m" },
  { name = "exciteddtsc", short = "cat 恒星", fatal = "50m", warn = "150m" },
}

local CHECK_INTERVAL = 10
local DISPLAY_WIDTH = 64
local DISPLAY_HEIGHT = 18
local USE_FAST_FLUID_QUERY = true

local gpu = component.isAvailable("gpu") and component.gpu or nil
local meInterface = nil
local meAddress = nil
local fastFluidQueryDisabled = false
local perf = {
  item = 0,
  fluid = 0,
  build = 0,
  draw = 0,
  total = 0,
  loops = 0,
  itemAvg = 0,
  fluidAvg = 0,
  buildAvg = 0,
  drawAvg = 0,
  totalAvg = 0,
  fluidMode = "fast",
}

local COLOR_OK = 0x00FF00
local COLOR_WARN = 0xFFFF00
local COLOR_FATAL = 0xFF0000

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

local function formatMs(seconds)
  return string.format("%.0fms", (tonumber(seconds) or 0) * 1000)
end

local function updateAverage(field, value)
  local avgField = field .. "Avg"
  local count = perf.loops
  if count <= 1 then
    perf[avgField] = value
  else
    perf[avgField] = perf[avgField] + (value - perf[avgField]) / count
  end
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

local function padLeft(text, width)
  text = tostring(text)
  local padding = width - textWidth(text)
  if padding <= 0 then
    return fitText(text, width)
  end
  return string.rep(" ", padding) .. text
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
    pcall(gpu.setResolution, DISPLAY_WIDTH, DISPLAY_HEIGHT)
    pcall(gpu.setViewport, DISPLAY_WIDTH, DISPLAY_HEIGHT)
    pcall(gpu.setForeground, COLOR_OK)
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
    local entry = lines[row] or ""
    local color = COLOR_OK
    local text = entry
    if type(entry) == "table" then
      text = entry.text or ""
      color = entry.color or COLOR_OK
    end

    local line = fitText(text, DISPLAY_WIDTH)
    if gpu ~= nil then
      pcall(gpu.setForeground, color)
      gpu.set(1, row, padRight(line, DISPLAY_WIDTH))
    else
      io.write(line .. "\n")
    end
  end

  if gpu ~= nil then
    pcall(gpu.setForeground, COLOR_OK)
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
    config.fatal = parseNumber(config.fatal or config.warn)
    config.warn = parseNumber(config.warn or config.fatal)
  end

  for _, config in ipairs(FLUID_CONFIGS) do
    config.fatal = parseNumber(config.fatal or config.warn)
    config.warn = parseNumber(config.warn or config.fatal)
  end
end

local function displayName(config)
  return config.short or config.label or config.name or "unknown"
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

local function getNetworkFluidAmounts()
  perf.fluidMode = "full"
  local fluids = safeCall(meInterface.getFluidsInNetwork) or {}
  local amounts = {}

  for _, fluid in ipairs(fluids) do
    if type(fluid) == "table" and (fluid.name ~= nil or fluid.label ~= nil) then
      local amount = tonumber(fluid.amount) or 0
      local added = {}

      for _, rawKey in ipairs({ fluid.name, fluid.label }) do
        if rawKey ~= nil then
          local key = tostring(rawKey)
          local lowerKey = key:lower()
          if not added[key] then
            added[key] = true
            amounts[key] = (amounts[key] or 0) + amount
          end
          if lowerKey ~= key and not added[lowerKey] then
            added[lowerKey] = true
            amounts[lowerKey] = (amounts[lowerKey] or 0) + amount
          end
        end
      end
    end
  end

  return amounts
end

local function getFluidAmountFromMap(config, amounts)
  local key = tostring(config.name or config.label or "")
  return amounts[key] or amounts[key:lower()] or 0
end

local function getFastFluidAmount(config)
  perf.fluidMode = "fast"
  local query = {}
  if config.name ~= nil and config.name ~= "" then
    query.name = config.name
  end

  local fluids = safeCall(meInterface.getFluidsInNetwork, query) or {}
  if #fluids > 20 then
    fastFluidQueryDisabled = true
    perf.fluidMode = "fallback"
    return nil
  end

  local total = 0
  local wanted = tostring(config.name or config.label or ""):lower()

  for _, fluid in ipairs(fluids) do
    if type(fluid) == "table" then
      local name = tostring(fluid.name or ""):lower()
      local label = tostring(fluid.label or ""):lower()
      if name == wanted or label == wanted then
        total = total + (tonumber(fluid.amount) or 0)
      end
    end
  end

  return total
end

local function getFluidAmount(config, amounts)
  if USE_FAST_FLUID_QUERY and not fastFluidQueryDisabled then
    local amount = getFastFluidAmount(config)
    if amount ~= nil then
      return amount
    end
    return nil
  end

  return getFluidAmountFromMap(config, amounts)
end

local function addStatusLine(lines, name, current, config)
  local status = "ok"
  local color = COLOR_OK
  if current < config.fatal then
    status = "fatal " .. formatNumber(config.fatal - current)
    color = COLOR_FATAL
  elseif current < config.warn then
    status = "warn " .. formatNumber(config.warn - current)
    color = COLOR_WARN
  end

  local text =
    padRight(name, 14) ..
    " " ..
    padLeft(formatNumber(current), 9) ..
    " / " ..
    padRight(formatNumber(config.warn), 8) ..
    " " ..
    padRight(status, 12)

  table.insert(lines, {
    color = color,
    text = text,
  })
end

local function buildScreen()
  local buildStart = computer.uptime()
  perf.item = 0
  perf.fluid = 0
  local fluidAmounts = nil
  if not USE_FAST_FLUID_QUERY or fastFluidQueryDisabled then
    local fluidStart = computer.uptime()
    fluidAmounts = getNetworkFluidAmounts()
    perf.fluid = perf.fluid + (computer.uptime() - fluidStart)
  end
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
      local itemStart = computer.uptime()
      local current = getItemAmount(config)
      perf.item = perf.item + (computer.uptime() - itemStart)
      if current < config.warn then
        missing = missing + 1
      end
      addStatusLine(lines, displayName(config), current, config)
    end

    for _, config in ipairs(FLUID_CONFIGS) do
      local fluidStart = computer.uptime()
      local current = getFluidAmount(config, fluidAmounts)
      perf.fluid = perf.fluid + (computer.uptime() - fluidStart)
      if current == nil then
        fluidStart = computer.uptime()
        fluidAmounts = getNetworkFluidAmounts()
        current = getFluidAmountFromMap(config, fluidAmounts)
        perf.fluid = perf.fluid + (computer.uptime() - fluidStart)
      end
      if current < config.warn then
        missing = missing + 1
      end
      addStatusLine(lines, displayName(config), current, config)
    end

    if missing == 0 then
      table.insert(lines, "All configured items and fluids are enough.")
    else
      table.insert(lines, "")
      table.insert(lines, "Missing entries: " .. tostring(missing))
    end
  end

  table.insert(lines, "")
  perf.build = computer.uptime() - buildStart
  table.insert(lines, string.format(
    "N i%s f%s b%s d%s t%s %s",
    formatMs(perf.item),
    formatMs(perf.fluid),
    formatMs(perf.build),
    formatMs(perf.draw),
    formatMs(perf.total),
    perf.fluidMode
  ))
  table.insert(lines, string.format(
    "A i%s f%s b%s d%s t%s",
    formatMs(perf.itemAvg),
    formatMs(perf.fluidAvg),
    formatMs(perf.buildAvg),
    formatMs(perf.drawAvg),
    formatMs(perf.totalAvg)
  ))
  table.insert(lines, "Refresh: " .. tostring(CHECK_INTERVAL) .. "s")
  return lines
end

local function main()
  initDisplay()
  normalizeConfigs()
  initMeInterface()

  while true do
    local loopStart = computer.uptime()
    local lines = buildScreen()
    local drawStart = computer.uptime()
    drawLines(lines)
    perf.draw = computer.uptime() - drawStart
    perf.total = computer.uptime() - loopStart
    perf.loops = perf.loops + 1
    updateAverage("item", perf.item)
    updateAverage("fluid", perf.fluid)
    updateAverage("build", perf.build)
    updateAverage("draw", perf.draw)
    updateAverage("total", perf.total)
    os.sleep(CHECK_INTERVAL)
  end
end

local ok, err = pcall(main)
if not ok then
  clearScreen()
  print("[fatal] " .. tostring(err))
end
