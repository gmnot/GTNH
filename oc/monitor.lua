local component = require("component")
local computer = require("computer")
local event = require("event")
local term = require("term")

local gtm = component.gt_machine
local gpu = component.isAvailable("gpu") and component.gpu or nil
local glasses = component.glasses

-- #region config

local textScale = 1
local glassesOffsetX = 3
local glassesOffsetY = 16
local exhaustWarningSeconds = 3600
local fluidCheckInterval = 10
local maxFluidDisplayLines = 8
local displayScientificNumbersIfAbove = 1e9

local FLUID_CONFIGS = {
    { name = "naquadah based liquid fuel mkvi (depleted)", short = "NqFuel VI D", fatal = "500k", warn = "1m" },
    { name = "naquadah based liquid fuel mkvi", short = "NqFuel VI", fatal = "50k", warn = "300k" },
    { name = "molten.eternity", short = "Eternity", fatal = "10m", warn = "40m" },
    { name = "temporalfluid"  , short = "Time", fatal = "10m", warn = "40m" },
    { name = "molten.infinity", short = "Inf", fatal = "500m", warn = "2g" },
    { name = "exciteddtec", short = "cat 4", fatal = "150m", warn = "500m" },
    { name = "exciteddtsc", short = "cat 5", fatal = "50m", warn = "150m" },
}

-- #endregion config

local SECOND_DATA_SIZE = 3600 * 24
local MAX_VOLTAGE_VALUE = 2147483640
local GT_SHOW_LOWER = 4

local VOLTAGE_NAME_COLOR = "\27[35m"
local SCREEN_RESET_COLOR = "\27[37m"
local SCREEN_GREEN_COLOR = "\27[32m"
local SCREEN_RED_COLOR = "\27[31m"

local GLASSES_RED_COLOR = { 255, 85, 85 }
local GLASSES_YELLOW_COLOR = { 255, 255, 85 }
local GLASSES_GREEN_COLOR = { 85, 255, 85 }
local GLASSES_WHITE_COLOR = { 255, 255, 255 }

local EU_Monitor = {
    secondEU = {},
    voltageNamesNoColor = {
        "ULV", "LV", "MV", "HV", "EV", "IV",
        "LUV", "ZPM", "UV", "UHV", "UEV", "UIV", "UMV", "UXV"
    },
    maxVoltageNameNoColor = "MAX",
    voltageNames = {},
    maxVoltageName = "",
}

for _, str in ipairs(EU_Monitor.voltageNamesNoColor) do
    table.insert(EU_Monitor.voltageNames, VOLTAGE_NAME_COLOR .. str .. SCREEN_RESET_COLOR)
end
EU_Monitor.maxVoltageName = VOLTAGE_NAME_COLOR .. EU_Monitor.maxVoltageNameNoColor .. SCREEN_RESET_COLOR

local texts = {}
local meInterface = nil
local nextFluidCheck = 0
local cachedFluidRows = {}
local cachedFluidScreenRows = {}
local cachedFluidOkCount = 0
local doContinue = true

local suffixMultipliers = { k = 1e3, m = 1e6, g = 1e9, t = 1e12 }

local function safeCall(fn, ...)
    local ok, result = pcall(fn, ...)
    if ok then return result end
    return nil
end

local function formatNumber(number)
    number = tonumber(number) or 0
    if math.abs(number) > displayScientificNumbersIfAbove then
        return string.format("%.2e", number)
    end
    local _, _, minus, int = string.format("%.1f", number):find("([-]?)(%d+)([.]?%d*)")
    int = int:reverse():gsub("(%d%d%d)", "%1,")
    return minus .. int:reverse():gsub("^,", "")
end

local function parseNumber(value)
    if type(value) == "number" then return value end
    local text = tostring(value or ""):lower()
    local numPart, suffix = text:match("^%s*([%d%.]+)%s*([kmgt]?)%s*$")
    local number = tonumber(numPart)
    if number == nil then error("invalid amount: " .. tostring(value)) end
    return number * (suffixMultipliers[suffix] or 1)
end

local function formatAmount(value)
    local number = tonumber(value) or 0
    for _, unit in ipairs({ { "t", 1e12 }, { "g", 1e9 }, { "m", 1e6 }, { "k", 1e3 } }) do
        if math.abs(number) >= unit[2] then
            return string.format("%.1f%s", number / unit[2], unit[1])
        end
    end
    return tostring(math.floor(number))
end

local function normalizeFluidConfigs()
    for _, config in ipairs(FLUID_CONFIGS) do
        config.fatal = parseNumber(config.fatal or config.warn)
        config.warn = parseNumber(config.warn or config.fatal)
    end
end

local function extractNumber(text)
    return tostring(text or ""):match("([%d,]+)")
end

local function getWirelessEU()
    local sensorInfo = gtm.getSensorInformation()
    local wirelessEUInfo = sensorInfo and sensorInfo[23]
    local match = extractNumber(wirelessEUInfo)
    if match then
        return tonumber((match:gsub(",", ""))) or 0
    end
    return 0
end

local function initMeInterface()
    if #FLUID_CONFIGS == 0 then return end
    for addr in component.list("me_interface", true) do
        local methods = safeCall(component.methods, addr) or {}
        if methods.getFluidsInNetwork ~= nil then
            meInterface = component.proxy(addr)
            return
        end
    end
end

local function getNetworkFluidAmounts()
    if meInterface == nil then return nil end
    local fluids = safeCall(meInterface.getFluidsInNetwork)
    if fluids == nil then return nil end

    local amounts = {}
    for _, fluid in ipairs(fluids) do
        if type(fluid) == "table" and (fluid.name ~= nil or fluid.label ~= nil) then
            local amount = tonumber(fluid.amount) or 0
            local seenKeys = {}
            for _, rawKey in ipairs({ fluid.name, fluid.label }) do
                if rawKey ~= nil then
                    local key = tostring(rawKey)
                    local lowerKey = key:lower()
                    for _, normalizedKey in ipairs({ key, lowerKey }) do
                        if not seenKeys[normalizedKey] then
                            seenKeys[normalizedKey] = true
                            amounts[normalizedKey] = (amounts[normalizedKey] or 0) + amount
                        end
                    end
                end
            end
        end
    end
    return amounts
end

local function getFluidAmount(amounts, config)
    local key = tostring(config.name or config.label or "")
    return amounts[key] or amounts[key:lower()] or 0
end

local function updateFluidRows()
    if #FLUID_CONFIGS == 0 then
        cachedFluidRows = {}
        cachedFluidScreenRows = {}
        cachedFluidOkCount = 0
        return
    end

    local now = computer.uptime()
    if now < nextFluidCheck then return end
    nextFluidCheck = now + fluidCheckInterval

    local amounts = getNetworkFluidAmounts()
    local rows = {}
    local screenRows = {}
    local okCount = 0
    local nameWidth = 0
    local amountWidth = 0
    local warnWidth = 0
    local screenItems = {}

    if amounts == nil then
        table.insert(rows, { text = "AE fluids: unavailable", color = GLASSES_RED_COLOR })
        table.insert(screenRows, "AE fluids: unavailable")
        cachedFluidRows = rows
        cachedFluidScreenRows = screenRows
        cachedFluidOkCount = 0
        return
    end

    for _, config in ipairs(FLUID_CONFIGS) do
        local current = getFluidAmount(amounts, config)
        local name = config.short or config.label or config.name
        local currentText = formatAmount(current)
        local warnText = formatAmount(config.warn)
        local text
        if current < config.fatal then
            text = string.format("%s: %s/%s fatal", name, currentText, warnText)
            table.insert(rows, { text = text, color = GLASSES_RED_COLOR })
        elseif current < config.warn then
            text = string.format("%s: %s/%s warn", name, currentText, warnText)
            table.insert(rows, { text = text, color = GLASSES_YELLOW_COLOR })
        else
            text = string.format("%s: %s/%s ok", name, currentText, warnText)
            okCount = okCount + 1
        end
        local status = current < config.fatal and "fatal" or current < config.warn and "warn" or "ok"
        nameWidth = math.max(nameWidth, string.len(name))
        amountWidth = math.max(amountWidth, string.len(currentText))
        warnWidth = math.max(warnWidth, string.len(warnText))
        table.insert(screenItems, {
            name = name,
            current = currentText,
            warn = warnText,
            status = status,
        })
    end

    for _, item in ipairs(screenItems) do
        table.insert(screenRows, string.format(
            "%-" .. tostring(nameWidth) .. "s  %" .. tostring(amountWidth) .. "s / %-" .. tostring(warnWidth) .. "s  %s",
            item.name,
            item.current,
            item.warn,
            item.status
        ))
    end

    cachedFluidRows = rows
    cachedFluidScreenRows = screenRows
    cachedFluidOkCount = okCount
end

local function createShadowText(key, x, y)
    y = y * 10
    texts[key .. "shadow"] = glasses.addTextLabel()
    texts[key .. "shadow"].setPosition(x + 1, y + 1)
    texts[key .. "shadow"].setScale(textScale)
    texts[key .. "shadow"].setColor(63 / 255, 63 / 255, 63 / 255)

    texts[key] = glasses.addTextLabel()
    texts[key].setPosition(x, y)
    texts[key].setScale(textScale)
    texts[key].setColor(1, 1, 1)
end

local function setShadowText(key, text, r, g, b)
    texts[key .. "shadow"].setText(text)
    texts[key].setText(text)
    if r == nil or g == nil or b == nil then return end
    texts[key .. "shadow"].setColor(r / 1028, g / 1028, b / 1028)
    texts[key].setColor(r / 255, g / 255, b / 255)
end

local function glassesSetup()
    glasses.removeAll()
    createShadowText("income_5m", glassesOffsetX, glassesOffsetY + 1)
    createShadowText("income_1h", glassesOffsetX, glassesOffsetY + 2)
    createShadowText("storage", glassesOffsetX, glassesOffsetY + 3)
    for i = 1, maxFluidDisplayLines do
        createShadowText("fluid_" .. tostring(i), glassesOffsetX, glassesOffsetY + 3 + i)
    end
    createShadowText("fluid_summary", glassesOffsetX, glassesOffsetY + 4 + maxFluidDisplayLines)
end

local function toColorString(value, width)
    local text = formatNumber(value)
    if width ~= nil then
        text = lpad(text, width)
    end
    if value == 0 then return text end
    local colorCode = value < 0 and SCREEN_RED_COLOR or SCREEN_GREEN_COLOR
    return string.format(colorCode .. "%s" .. SCREEN_RESET_COLOR, text)
end

local function getGTInfo(euPerTick, withColor)
    withColor = withColor == nil or withColor
    local voltageNames = withColor and EU_Monitor.voltageNames or EU_Monitor.voltageNamesNoColor
    local maxVoltageName = withColor and EU_Monitor.maxVoltageName or EU_Monitor.maxVoltageNameNoColor
    if euPerTick == 0 then return "0A " .. voltageNames[1] end

    local absValue = math.abs(euPerTick)
    if absValue >= MAX_VOLTAGE_VALUE then
        if not withColor then
            return string.format("%sA", formatNumber(absValue / MAX_VOLTAGE_VALUE))
        end
        return string.format("%sA %s", formatNumber(absValue / MAX_VOLTAGE_VALUE), maxVoltageName)
    end

    local voltageForTier = absValue / 2 / (4 ^ GT_SHOW_LOWER)
    local tier = voltageForTier < 4 and 1 or math.floor(math.log(voltageForTier) / math.log(4))
    if tier > #voltageNames then
        if not withColor then
            return string.format("%sA", formatNumber(absValue / MAX_VOLTAGE_VALUE))
        end
        return string.format("%sA %s", formatNumber(absValue / MAX_VOLTAGE_VALUE), maxVoltageName)
    end

    tier = math.max(1, math.min(tier, #voltageNames))
    local baseVoltage = 8 * (4 ^ (tier - 1))
    local current = absValue / baseVoltage
    return string.format("%.0fA %s", current, voltageNames[tier])
end

local function calculateAverage(data, n)
    local count = math.min(n, #data)
    if count == 0 then return 0 end
    return (data[1] - data[count]) / count
end

local function formatTimeFromSeconds(seconds)
    if seconds == nil or seconds <= 0 then return "N/A" end
    if seconds < 60 then return string.format("%.1f 秒", seconds) end
    if seconds < 3600 then return string.format("%.1f 分钟", seconds / 60) end
    if seconds < 86400 then return string.format("%.1f 小时", seconds / 3600) end
    if seconds < 2592000 then return string.format("%.1f 天", seconds / 86400) end
    if seconds < 31536000 then return string.format("%.1f 月", seconds / 2592000) end
    if seconds < 31536000 * 1000 then return string.format("%.1f 年", seconds / 31536000) end
    return ">1000年"
end

local function restoreViewport()
    if gpu == nil then return end
    local width, height = gpu.getResolution()
    if width ~= nil and height ~= nil and gpu.setViewport ~= nil then
        pcall(gpu.setViewport, width, height)
    end
end

function EU_Monitor.update()
    local currentEU = getWirelessEU()
    table.insert(EU_Monitor.secondEU, 1, currentEU)
    if #EU_Monitor.secondEU > SECOND_DATA_SIZE then
        table.remove(EU_Monitor.secondEU)
    end

    local fiveSecAvg = calculateAverage(EU_Monitor.secondEU, 5) / 20
    local minuteAvg = calculateAverage(EU_Monitor.secondEU, 60) / 20
    local fiveMinAvg = calculateAverage(EU_Monitor.secondEU, 300) / 20
    local hourAvg = calculateAverage(EU_Monitor.secondEU, 3600) / 20
    local dayAvg = calculateAverage(EU_Monitor.secondEU, 86400) / 20
    updateFluidRows()

    term.clear()
    term.setCursor(1, 1)
    print(string.format("%-16s %12.2e EU", "存量:", currentEU))
    print(string.format("%-16s %12.1e EU/s    (%s)", "可用功率(秒):", currentEU / 20, getGTInfo(currentEU / 20)))
    print(string.format("%-16s %12.1e EU/hour (%s)", "可用功率(小时):", currentEU / 3600 / 20, getGTInfo(currentEU / 3600 / 20)))
    print(string.format("%-16s %12.1e EU/day  (%s)", "可用功率(天):", currentEU / 3600 / 20 / 24, getGTInfo(currentEU / 3600 / 20 / 24)))
    print()
    print(string.format("%-16s %16s EU/t (%s)", "每五秒均值:", toColorString(fiveSecAvg, 16), getGTInfo(fiveSecAvg)))
    print(string.format("%-16s %16s EU/t (%s)", "每分钟均值:", toColorString(minuteAvg, 16), getGTInfo(minuteAvg)))
    print(string.format("%-16s %16s EU/t (%s)", "五分钟均值:", toColorString(fiveMinAvg, 16), getGTInfo(fiveMinAvg)))
    print(string.format("%-16s %16s EU/t (%s)", "每小时均值:", toColorString(hourAvg, 16), getGTInfo(hourAvg)))
    print(string.format("%-16s %16s EU/t (%s)", "每天均值:", toColorString(dayAvg, 16), getGTInfo(dayAvg)))
    print(string.format("流体: 告警 %d, 满足 %d", #cachedFluidRows, cachedFluidOkCount))
    for _, row in ipairs(cachedFluidScreenRows) do
        print(row)
    end
    print()
    print("(按 Ctrl+C 关闭程序)")

    local exhaustSeconds = nil
    if hourAvg < 0 then
        exhaustSeconds = currentEU / (-hourAvg) / 20
    end

    setShadowText("income_5m", string.format("5m: %s EU/t (%s)", formatNumber(fiveMinAvg), getGTInfo(fiveMinAvg, false)),
        table.unpack(fiveMinAvg < 0 and GLASSES_RED_COLOR or fiveMinAvg > 0 and GLASSES_GREEN_COLOR or GLASSES_WHITE_COLOR))
    setShadowText("income_1h", string.format("1h: %s EU/t (%s)", formatNumber(hourAvg), getGTInfo(hourAvg, false)),
        table.unpack(hourAvg < 0 and GLASSES_RED_COLOR or hourAvg > 0 and GLASSES_GREEN_COLOR or GLASSES_WHITE_COLOR))
    setShadowText("storage", string.format("储量: %s EU  耗尽: %s", formatNumber(currentEU), formatTimeFromSeconds(exhaustSeconds)),
        table.unpack((exhaustSeconds ~= nil and exhaustSeconds < exhaustWarningSeconds) and GLASSES_RED_COLOR or GLASSES_WHITE_COLOR))

    for i = 1, maxFluidDisplayLines do
        local row = cachedFluidRows[i]
        if row == nil then
            setShadowText("fluid_" .. tostring(i), "")
        else
            setShadowText("fluid_" .. tostring(i), row.text, table.unpack(row.color))
        end
    end

    local summaryY = (glassesOffsetY + 4 + math.min(#cachedFluidRows, maxFluidDisplayLines)) * 10
    texts["fluid_summaryshadow"].setPosition(glassesOffsetX + 1, summaryY + 1)
    texts["fluid_summary"].setPosition(glassesOffsetX, summaryY)
    setShadowText("fluid_summary", string.format("%d targets ok", cachedFluidOkCount), table.unpack(GLASSES_GREEN_COLOR))
end

local function onInterrupted()
    doContinue = false
end

local function main()
    event.listen("interrupted", onInterrupted)
    normalizeFluidConfigs()
    initMeInterface()
    restoreViewport()
    glassesSetup()
    term.clear()
    term.setCursor(1, 1)
    term.setCursorBlink(false)

    while doContinue do
        EU_Monitor.update()
        os.sleep(1)
    end

    event.ignore("interrupted", onInterrupted)
end

main()
