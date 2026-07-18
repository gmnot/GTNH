local component = require("component")
local os = require("os")

local rawPrint = print
local gpu = component.isAvailable("gpu") and component.gpu or nil
local DISPLAY_WIDTH, DISPLAY_HEIGHT = 48, 15
local displayLines, blankLine = {}, string.rep(" ", DISPLAY_WIDTH)

local function charInfo(s, i)
    local b = s:byte(i)
    if b < 0x80 then return 1, 1 end
    if b < 0xE0 then return 2, 2 end
    if b < 0xF0 then return 3, 2 end
    return 4, 2
end

local function pushDisplayLine(line)
    for textLine in (tostring(line):gsub("\r\n?", "\n") .. "\n"):gmatch("(.-)\n") do
        local chunk, width, i = "", 0, 1
        while i <= #textLine do
            local len, charWidth = charInfo(textLine, i)
            if width > 0 and width + charWidth > DISPLAY_WIDTH then
                table.insert(displayLines, chunk)
                chunk, width = "", 0
            end
            chunk = chunk .. textLine:sub(i, i + len - 1)
            width = width + charWidth
            i = i + len
        end
        table.insert(displayLines, chunk)
        while #displayLines > DISPLAY_HEIGHT do table.remove(displayLines, 1) end
    end
    if gpu then
        for i = 1, DISPLAY_HEIGHT do gpu.set(1, i, (displayLines[i] or "") .. blankLine) end
    end
end

if gpu then gpu.setViewport(DISPLAY_WIDTH, DISPLAY_HEIGHT) gpu.setForeground(0x00FF00) end

local function print(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[i] = tostring(select(i, ...)) end
    local line = table.concat(parts, "\t")
    rawPrint(line)
    pushDisplayLine(line)
end
 
-- 配置: {流体注册名, 缓存阈值(mB), 行星, 气体}; 阈值支持 k/m/g/t 后缀
local FLUID_CONFIGS = {       
    {"liquidair", "8g", 8, 2},
    {"molten.copper", "40g", 8, 3},
    {"molten.iron", "40g", 4, 2},
    {"hydrogen", "100g", 8, 1},
    {"helium", "60g", 5, 4},
    {"fluorine", "30g", 7, 2},
    {"hydrofluoricacid_gt5u", "30g", 7, 1},
    {"oxygen", "80g", 7, 4},
    {"ic2distilledwater", "30g", 8, 5},
    {"saltwater", "30g", 5, 3},
    {"sulfuricacid", "30g", 4, 1},
    {"liquid_heavy_oil", "40g", 4, 4},
    {"oil", "30g", 4, 3},
    {"helium-3", "30g", 5, 2},
    {"deuterium", "30g", 6, 1},
    {"tritium", "30g", 6, 2},
    {"nitrogen", "100g", 7, 3},
    {"ammonia", "30g", 6, 3},
    {"ethylene", "2g", 6, 5},
    -- {"unknowwater", "2g", 8, 4},
    {"lava", "1g", 3, 3},
    {"methane", "1g", 5, 9},
    {"argon", "100m", 5, 7},
    {"radon", "100g", 8, 6},
    {"xenon", "20g", 6, 4},
    {"krypton", "100g", 5, 8},
    {"molten.lead", "4g", 4, 5},
    {"chlorobenzene", "100m", 2, 1},
    {"endergoo", "500m", 3, 1},
    {"molten.copper", "240g", 8, 3},
    {"molten.iron", "240g", 4, 2},
}
 
-- 多台机器地址和等级: {地址, 等级}
local MACHINES = {
    {"address", 2},
}
 
local AUTO_DISCOVER_MACHINES, DEFAULT_MACHINE_LEVEL = true, 2
local CHECK_INTERVAL, MAX_STOP_WAIT = 60, 60

local suffixMultipliers = {k = 1e3, m = 1e6, g = 1e9, t = 1e12}
local function parseNumberWithSuffix(value)
    if type(value) == "number" then return value end
    if value == "-1" then return -1 end
    local numPart, suffix = value:match("^([%d%.]+)([kmgt]?)$")
    local number = tonumber(numPart)
    if not number then error("无效的数字格式: " .. tostring(value)) end
    return number * (suffixMultipliers[suffix] or 1)
end

local function formatNumberReadable(number)
    if number == -1 then return "-1 (持续获取)" end
    for _, unit in ipairs({{"t", 1e12}, {"g", 1e9}, {"m", 1e6}, {"k", 1e3}}) do
        if math.abs(number) >= unit[2] then return string.format("%.1f%s", number / unit[2], unit[1]) end
    end
    return tostring(number)
end
if not component.isAvailable("me_interface") then
    print("错误：未检测到ME接口，脚本终止") os.exit()
end
for _, config in ipairs(FLUID_CONFIGS) do if type(config[2]) == "string" then config[2] = parseNumberWithSuffix(config[2]) end end
local gt_machines, machineAddresses, machineLevels, discoveredMachines = {}, {}, {}, {}
local machineCount = 0

local function addMachine(address, level, message)
    local success, machine = pcall(component.proxy, address)
    if not (success and machine and machine.type == "gt_machine") then return false end
    local machineAddress = machine.address or address
    if not discoveredMachines[machineAddress] then
        table.insert(gt_machines, machine)
        table.insert(machineAddresses, machineAddress)
        discoveredMachines[machineAddress] = true
        machineCount = machineCount + 1
    end
    machineLevels[machineAddress] = level
    print(string.format(message, machineAddress, level))
    return true
end

if AUTO_DISCOVER_MACHINES then
    for address in component.list("gt_machine", true) do
        addMachine(address, DEFAULT_MACHINE_LEVEL, "Found machine: %s (level %d)")
    end
end

for _, machineInfo in ipairs(MACHINES) do
    local address = machineInfo[1]
    if address ~= "address" and not addMachine(address, machineInfo[2] or 1, "找到机器: %s (等级 %d)") then
        print("警告: 无法访问机器 " .. address)
    end
end
if machineCount == 0 then print("错误：未找到任何可用的太空钻机，脚本终止") os.exit() end
print("成功初始化 " .. machineCount .. " 台钻机")
local function getFluidAmount(fluidName)
    local fluids = component.me_interface.getFluidsInNetwork()
    for _, fluid in ipairs(fluids) do if fluid.name == fluidName then return tonumber(fluid.amount) or 0 end end
    return 0
end
local function anyFluidNeedsRefill(ignoreFluid)
    for _, config in ipairs(FLUID_CONFIGS) do
        if config[2] ~= -1 and config[1] ~= ignoreFluid then
            local amount = getFluidAmount(config[1])
            if amount < config[2] then return true, config, amount, config[2] end
        end
    end
    return false, nil
end

local function safelyStopMachine(machine)
    machine.setWorkAllowed(false)
    if machine.isMachineActive() then
        local waitCount = 0
        while machine.isMachineActive() and waitCount < MAX_STOP_WAIT do os.sleep(1) waitCount = waitCount + 1 end
        if waitCount >= MAX_STOP_WAIT then print("警告：机器停止超时") return false end
    end
    return true
end
local function safelyStopAllMachines()
    local allStopped = true
    for i, machine in ipairs(gt_machines) do
        local stopped = safelyStopMachine(machine)
        if not stopped then print("警告：机器 " .. i .. " 停止失败") end
        allStopped = stopped and allStopped
    end
    return allStopped
end
local function adjustMachineParameters(machine, level, param1, param2)
    if not safelyStopMachine(machine) then print("无法停止机器，参数调整取消") return false end
    local success = true
    for _, hatch in ipairs(level == 1 and {0} or {0, 2, 4, 6}) do
        success = success and pcall(machine.setParameters, hatch, 0, param1)
        success = success and pcall(machine.setParameters, hatch, 1, param2)
    end
    if success then machine.setWorkAllowed(true) return true end
    print("机器参数调整失败") return false
end
local function adjustAllMachinesParameters(param1, param2)
    local successCount = 0
    for i, machine in ipairs(gt_machines) do
        local address = machineAddresses[i] or tostring(machine.address)
        local level = machineLevels[address] or 1
        local success = adjustMachineParameters(machine, level, param1, param2)
        if success then successCount = successCount + 1 print(string.format("机器 %d (等级 %d) 参数调整成功", i, level))
        else print(string.format("机器 %d (等级 %d) 参数调整失败", i, level)) end
    end
    return successCount
end
local function checkAllFluids()
    local needsRefill, refillConfig, currentAmount, targetAmount = anyFluidNeedsRefill()
    if needsRefill then
        local fluidName = refillConfig[1]
        print(string.format("检测到需要补充的流体: %s, 当前 %s / 目标 %s", fluidName, formatNumberReadable(currentAmount), formatNumberReadable(targetAmount)))
        local successCount = adjustAllMachinesParameters(refillConfig[3], refillConfig[4])
        if successCount > 0 then
            print(string.format("已调整 %d 台机器参数以补充 %s", successCount, fluidName))
            return true
        end
        print("所有机器参数调整失败")
    else
        for _, config in ipairs(FLUID_CONFIGS) do
            if config[2] == -1 then
                print(string.format("所有常规流体充足，开始持续获取 %s", config[1]))
                local successCount = adjustAllMachinesParameters(config[3], config[4])
                if successCount > 0 then print(string.format("已调整 %d 台机器参数以持续获取 %s", successCount, config[1])) return true
                else print("所有机器参数调整失败") end
            end
        end
        print("所有流体库存充足，无需调整")
        safelyStopAllMachines()
    end
    return false
end
local function main()
    print("太空钻机流体监控系统启动")
    print(string.format("间隔:%ds\n流体:%d\n机器:%d", CHECK_INTERVAL, #FLUID_CONFIGS, #gt_machines))
    for i, machine in ipairs(gt_machines) do
        local address = machineAddresses[i] or tostring(machine.address)
        local level = machineLevels[address] or 1
        print(string.format("机器 %d: 等级 %d", i, level))
    end
    print("\n当前流体监控配置:")
    for _, config in ipairs(FLUID_CONFIGS) do
        local readableThreshold = formatNumberReadable(config[2])
        print(string.format("  %s: %s (参数: %d, %d)", config[1], readableThreshold, config[3], config[4]))
    end
    while true do
        print("\n--- 开始流体检查 ---")
        checkAllFluids()
        print("等待下一次检查...")
        os.sleep(CHECK_INTERVAL)
    end
end
main()
