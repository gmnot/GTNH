local os = require("os")
local component = require("component")
local sides = require("sides")
 
-- ===================== 流体ID配置 =====================
local FLUID_PLASMA = "plasma.helium"       -- 氦等离子体
local FLUID_SUPERCOOLANT = "supercoolant"  -- 超级冷却液
 
local sidePlasma = sides.down           -- 转运器 对应的 等离子输入的方向，方向1
local sideCoolant = sides.west          -- 转运器 对应的 超级冷却液输入的方向，方向2
local sideAEInterface = sides.east      -- 转运器 对应的 AE接口输入的方向，方向3
 
local function findFluidSlot(targetSide, fluidId)
    local tankCount = component.transposer.getTankCount(targetSide)
    for tank = 1, tankCount do
        local fluidInfo = component.transposer.getFluidInTank(targetSide, tank)
        if fluidInfo and fluidInfo.name == fluidId then
            return tank - 1  -- 转换为转运器需要的0-based索引
        end
    end
    return nil
end

local function findPurificationUnit() -- 寻找五级净化水控制器

    for address, _ in component.list("gt_machine") do

        local machine =
            component.proxy(address)

        local info =
            machine.getSensorInformation()

        for _, value in ipairs(info) do

            if string.find(
                value,
                "purification_unit_plasma_heater.temperature"
            ) then

                print("找到五级净化水控制器:")
                print(address)
                return machine

            end

        end

    end

    return nil

end
 
local function main()
    os.execute("cls")
    print("正在运行中...")

    local gtm = findPurificationUnit()

    if gtm == nil then
        print("没有找到五级净化水控制器")
    else
        print("连接成功")
    end
 
    local lastCycle = nil -- 用于记录上一次的 cycle 值
 
    while true do
        os.sleep(0.5)
        
        if gtm.getWorkProgress() > 0 then
            local info = gtm.getSensorInformation()
            if info[4] ~= nil and info[5] ~= nil then
                local temperature = tonumber(string.match(info[4], "%d+$")) -- 截取 temperature 的末尾数字部分
                local cycle = tonumber(string.match(info[5], "%d+$")) -- 截取 cycle 的末尾数字部分
                if lastCycle ~= nil and lastCycle == 3 and cycle == 0 then
                    print("正在运行中...") -- 清屏后重新打印标题
                end
                lastCycle = cycle -- 更新记录
 
                if cycle < 3 then
                    print("cicle:"..cycle)
                    while component.transposer.getTankLevel(sideCoolant) ~= 0 do
                        os.sleep(1)
                    end
                    while component.transposer.getTankLevel(sidePlasma) ~= 0 do
                        os.sleep(1)
                    end
 
                    if temperature == 0 then
                        local plasmaSlot = findFluidSlot(sideAEInterface, FLUID_PLASMA)
                        if plasmaSlot then
                            component.transposer.transferFluid(sideAEInterface, sidePlasma, 100, plasmaSlot)
                        end
                        for i = 1, 10 do
                            os.sleep(1)  -- 加热
                            print("当前温度:"..tonumber(string.match(gtm.getSensorInformation()[4], "%d+$")).."K") -- 不想看到温度可以删去
                        end
                    else
                        local coolantSlot = findFluidSlot(sideAEInterface, FLUID_SUPERCOOLANT)
                        if coolantSlot then
                            component.transposer.transferFluid(sideAEInterface, sideCoolant, 2000, coolantSlot)
                        end
                        for i = 1, 20 do
                            os.sleep(1)  -- 休眠等待冷却
                            print("当前温度:"..tonumber(string.match(gtm.getSensorInformation()[4], "%d+$")).."K") -- 不想看到温度可以删去
                        end
                    end
                end
            end
        end
    end
end
 
main()