local component = require("component")
local os = require("os")
 
--          配置区域（可修改）
-- 格式: {流体注册名, 缓存阈值(mB), 行星, 气体}
-- 缓存阈值支持单位后缀: k=千(10^3), m=百万(10^6), g=十亿(10^9), t=万亿(10^12)
local FLUID_CONFIGS = {       
    {"liquidair", "1g", 8, 2},
    {"molten.copper", "6g", 8, 3},
    {"molten.iron", "6g", 4, 2},
    {"fluorine", "4g", 7, 2},
    {"hydrofluoricacid_gt5u", "4g", 7, 1},
    {"ic2distilledwater", "6g", 8, 5},
    {"saltwater", "6g", 5, 3},
    {"sulfuricacid", "1g", 4, 1},
    {"oil", "1g", 4, 3},
    {"helium", "1g", 5, 4},
    {"helium-3", "6g", 5, 2},
    {"deuterium", "6g", 6, 1},
    {"tritium", "6g", 6, 2},
    {"ammonia", "6g", 6, 3},
    {"ethylene", "2g", 6, 5},
    {"lava", "1g", 3, 3},
    {"methane", "1g", 5, 9},
    -- {"molten.tin", "100m", 8, 7},
    -- {"molten.lead", "100m", 4, 5},
    {"argon", "100m", 5, 7},
    {"radon", "2g", 8, 6},
    {"krypton", "100m", 5, 8},
    {"xenon", "2g", 6, 4},
    {"chlorobenzene", "100m", 2, 1},
    -- 在此处添加更多流体配置，按优先级从高到低排列
}
 
-- 多台机器地址列表和等级（需要替换为实际的机器地址和等级）格式: {地址, 等级}
local MACHINES = {
    {"address", 2},
    -- 在此处添加更多机器地址和等级
}
 
-- 检测间隔(秒)
local AUTO_DISCOVER_MACHINES = true
local DEFAULT_MACHINE_LEVEL = 1

local CHECK_INTERVAL = 15
 
----函数部分
local function parseNumberWithSuffix(value)
    if type(value) == "number" then return value end
    if type(value) ~= "string" then error("无效的数字格式: " .. tostring(value)) end
    if value == "-1" then return -1 end
    local numPart, suffix = value:match("^([%d%.]+)([kmgt]?)$")
    if not numPart then error("无法解析数字: " .. value) end
    local number = tonumber(numPart)
    if not number then error("无效的数字: " .. numPart) end
    if suffix == "k" then return number * 1e3
    elseif suffix == "m" then return number * 1e6
    elseif suffix == "g" then return number * 1e9
    elseif suffix == "t" then return number * 1e12
    else return number end
end
local function formatNumberReadable(number)
    if number == -1 then return "-1 (持续获取)" end
    local absNumber = math.abs(number)
    if absNumber >= 1e12 then return string.format("%.1ft", number / 1e12)
    elseif absNumber >= 1e9 then return string.format("%.1fg", number / 1e9)
    elseif absNumber >= 1e6 then return string.format("%.1fm", number / 1e6)
    elseif absNumber >= 1e3 then return string.format("%.1fk", number / 1e3)
    else return tostring(number) end
end
if not component.isAvailable("me_interface") then
    print("错误：未检测到ME接口，脚本终止") os.exit()
end
local PROCESSED_FLUID_CONFIGS = {}
for _, config in ipairs(FLUID_CONFIGS) do
    local threshold = config[2]
    if type(threshold) == "string" and threshold ~= "-1" then threshold = parseNumberWithSuffix(threshold) end
    table.insert(PROCESSED_FLUID_CONFIGS, {config[1], threshold, config[3], config[4]})
end
local gt_machines = {}
local machineAddresses = {}
local machineCount = 0
local machineLevels = {}

if AUTO_DISCOVER_MACHINES then
    for address in component.list("gt_machine", true) do
        local success, machine = pcall(component.proxy, address)
        if success and machine and machine.type == "gt_machine" then
            table.insert(gt_machines, machine)
            table.insert(machineAddresses, address)
            machineLevels[address] = DEFAULT_MACHINE_LEVEL
            machineCount = machineCount + 1
            print("Found machine: " .. address .. " (level " .. DEFAULT_MACHINE_LEVEL .. ")")
        end
    end
end

for _, machineInfo in ipairs(MACHINES) do
    local address = machineInfo[1]
    local level = machineInfo[2] or 1
    if address ~= "address" and not machineLevels[address] then
    local success, machine = pcall(component.proxy, address)
    if success and machine and machine.type == "gt_machine" then
        table.insert(gt_machines, machine)
        table.insert(machineAddresses, address)
        machineLevels[address] = level
        machineCount = machineCount + 1
        print("找到机器: " .. address .. " (等级 " .. level .. ")")
    else print("警告: 无法访问机器 " .. address) end
end
    if address ~= "address" and machineLevels[address] then machineLevels[address] = level end
end
if machineCount == 0 then print("错误：未找到任何可用的太空钻机，脚本终止") os.exit() end
print("成功初始化 " .. machineCount .. " 台钻机")
local function getFluidAmount(fluidName)
    local fluids = component.me_interface.getFluidsInNetwork()
    for _, fluid in ipairs(fluids) do if fluid.name == fluidName then return tonumber(fluid.amount) or 0 end end
    return 0
end
local function anyFluidNeedsRefill(ignoreFluid)
    for _, config in ipairs(PROCESSED_FLUID_CONFIGS) do
        local fluidName = config[1]
        local threshold = config[2]
        if threshold ~= -1 and fluidName ~= ignoreFluid then
            local amount = getFluidAmount(fluidName)
            if amount < threshold then return true, fluidName, amount, threshold end
        end
    end
    return false, nil
end
local function safelyStopMachine(machine)
    machine.setWorkAllowed(false)
    if machine.isMachineActive() then
        local maxWait = 60
        local waitCount = 0
        while machine.isMachineActive() and waitCount < maxWait do os.sleep(1) waitCount = waitCount + 1 end
        if waitCount >= maxWait then print("警告：机器停止超时") return false end
    end
    return true
end
local function safelyStopAllMachines()
    local allStopped = true
    for i, machine in ipairs(gt_machines) do
        if not safelyStopMachine(machine) then print("警告：机器 " .. i .. " 停止失败") allStopped = false end
    end
    return allStopped
end
local function adjustMachineParametersLevel1(machine, param1, param2)
    if safelyStopMachine(machine) then
        local success1 = pcall(machine.setParameters, 0, 0, param1)
        local success2 = pcall(machine.setParameters, 0, 1, param2)
        if success1 and success2 then machine.setWorkAllowed(true) return true
        else print("机器参数调整失败") return false end
    else print("无法停止机器，参数调整取消") return false end
end
local function adjustMachineParametersLevel23(machine, param1, param2)
    if safelyStopMachine(machine) then
        local success = true
        success = success and pcall(machine.setParameters, 0, 0, param1)
        success = success and pcall(machine.setParameters, 0, 1, param2)
        success = success and pcall(machine.setParameters, 2, 0, param1)
        success = success and pcall(machine.setParameters, 2, 1, param2)
        success = success and pcall(machine.setParameters, 4, 0, param1)
        success = success and pcall(machine.setParameters, 4, 1, param2)
        success = success and pcall(machine.setParameters, 6, 0, param1)
        success = success and pcall(machine.setParameters, 6, 1, param2)
        if success then machine.setWorkAllowed(true) return true
        else print("机器参数调整失败") return false end
    else print("无法停止机器，参数调整取消") return false end
end
local function adjustAllMachinesParameters(param1, param2)
    local successCount = 0
    for i, machine in ipairs(gt_machines) do
        local address = machineAddresses[i] or tostring(machine.address)
        local level = machineLevels[address] or 1
        local success
        if level == 1 then success = adjustMachineParametersLevel1(machine, param1, param2)
        else success = adjustMachineParametersLevel23(machine, param1, param2) end
        if success then successCount = successCount + 1 print(string.format("机器 %d (等级 %d) 参数调整成功", i, level))
        else print(string.format("机器 %d (等级 %d) 参数调整失败", i, level)) end
    end
    return successCount
end
local function checkAllFluids()
    local needsRefill, refillFluid, currentAmount, targetAmount = anyFluidNeedsRefill()
    if needsRefill then
        print(string.format("检测到需要补充的流体: %s, 当前 %s / 目标 %s", refillFluid, formatNumberReadable(currentAmount), formatNumberReadable(targetAmount)))
        for _, config in ipairs(PROCESSED_FLUID_CONFIGS) do
            local fluidName = config[1]
            local threshold = config[2]
            local param1 = config[3]
            local param2 = config[4]
            if fluidName == refillFluid then
                local successCount = adjustAllMachinesParameters(param1, param2)
                if successCount > 0 then print(string.format("已调整 %d 台机器参数以补充 %s", successCount, fluidName)) return true
                else print("所有机器参数调整失败") end break
            end
        end
    else
        for _, config in ipairs(PROCESSED_FLUID_CONFIGS) do
            local fluidName = config[1]
            local threshold = config[2]
            local param1 = config[3]
            local param2 = config[4]
            if threshold == -1 then
                print(string.format("所有常规流体充足，开始持续获取 %s", fluidName))
                local successCount = adjustAllMachinesParameters(param1, param2)
                if successCount > 0 then print(string.format("已调整 %d 台机器参数以持续获取 %s", successCount, fluidName)) return true
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
    print("监控间隔: " .. CHECK_INTERVAL .. "秒")
    print("监控流体数量: " .. #PROCESSED_FLUID_CONFIGS)
    print("管理机器数量: " .. #gt_machines)
    for i, machine in ipairs(gt_machines) do
        local address = machineAddresses[i] or tostring(machine.address)
        local level = machineLevels[address] or 1
        print(string.format("机器 %d: 等级 %d", i, level))
    end
    print("\n当前流体监控配置:")
    for _, config in ipairs(PROCESSED_FLUID_CONFIGS) do
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