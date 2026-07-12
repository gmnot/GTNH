local os = require("os")
local component = require("component")
local sides = require("sides")

local trans = component.transposer
local sideCacheBuffer = sides.down       -- 转运器对应的 大型原料缓存仓
local sideAEInfusion = sides.north       -- 转运器对应的 ae的物质聚合器
local sideInterface = sides.east         -- 转运器对应的 主网也是是唯一的ae接口 用于设置流体的输出
local database = component.database
local mei = component.me_interface
local gtm = component.gt_machine
 
local fcFluidDrop = "ae2fc:fluid_drop"
local GTMaterial = {
    [2129] = "Neutronium", [0] = "Draconium", [2976] = "DraconiumAwakened",        -- GT材料的处理 因为部分材料对应的等离子单元查找不到
    [2978] = "Ichorium", [2982] = "CosmicNeutronium", [2984] = "Flerovium_GT5U",      -- 同时生成的单元没有对应的液体名称 故此手动标记全部gt材料 因为比较少
    [2397] = "Infinity", [2329] = "Tritanium", [2395] = "Bedrockium"}           -- 分别是 中子、龙、觉醒龙、灵宝、黑中子、夫(金字旁的)、无尽、三钛、基岩 防止oc出问题
 
function setAE2FCPlasma(materialName)
    database.set( 1, fcFluidDrop, 0, "{Fluid:plasma." .. materialName .. "}")
end
 
function clearCacheBuffer()     -- 由于 磁物质 的原料输出是 1粉+2流体 固定的,故此直接写死清除的逻辑
    trans.transferItem(sideCacheBuffer, sideAEInfusion, _, 1)
end
 
function requestItem(item)
    local tet = true
    local cacheN = 0        -- 用于检测下单失败的次数 同时作为用于 取消订单 的阈值
    ::retryRequest::
    local craftable = mei.getCraftables({name=item.name, label=item.label})[1]
 
    if trans.getFluidInTank(sideInterface, 1).amount >= 8000 then return end     -- 实测由于ae延迟什么的 导致的在这死循环问题
 
    if not craftable then   -- 等待玩家检查样板
        if tet then
            tet = false
            print("未查找到对应的液滴可下单 ".. item.label .. " ,请检查。正在等待。。。") 
        end
        os.sleep(5)
        goto retryRequest
    end
 
    local result = craftable.request(1, true)      -- 没有问题就执行下单
    tet = true
    print("已经下单相关物品", item.label)
    os.sleep(2)
 
    if result.hasFailed() or result.isCanceled() then
        print("下单失败,5s之后尝试重新下单")
        cacheN = cacheN + 1
        if cacheN >= 12 then
            os.sleep(20)
            if cacheN > 15 then 
                print("遇到严重问题 请手动维护....")
                while true do os.sleep(5) end
            end
            local cpus = mei.getCpus()
            for i=1,#cpus do     -- 下单失败次数过多 ae那边可能出问题了 先尝试取消订单
                local out = cpus[i].cpu.finalOutput()
                if out == nil then break end
                if out.name == item.name and out.label == item.label then
                    cpus[i].cpu.cancel()
                end
            end
        end
        os.sleep(5)
        goto retryRequest
    end
 
    while not result.isDone() do
        os.sleep(2)
    end
end
 
function main()
 
    os.execute("cls")
 
    while true do
 
        local item = trans.getStackInSlot(sideCacheBuffer, 1)
 
        if item ~= nil then
            print("即将执行数据库初始化。。。")
            -- 获取配方对应的等离子数量
            local fluidAmount = math.abs(trans.getFluidInTank(sideCacheBuffer, 1).amount - trans.getFluidInTank(sideCacheBuffer, 2).amount) * 144
            -- 数据库设置对应的等离子
            local materialName
            if item.name:match("miscutils:itemDust*") ~= nil then   -- 对于GT++的材料进行处理 直接生成对应的液滴
                materialName = string.lower(string.match(item.name, "miscutils:itemDust" .. "(%w+)$"))
            else -- 除了GT++的材料 没有bart的材料 如果之后出现了 再处理
                materialName = string.lower(GTMaterial[item.damage])
            end
            setAE2FCPlasma(materialName)
            clearCacheBuffer()      -- 清除材料缓存器的液体/物品
            os.sleep(0.25)
 
            print("即将执行等离子的处理操作。。。")
            mei.setFluidInterfaceConfiguration(0, database.address, 1)      -- 标记接口处的流体
            os.sleep(0.25)          -- 一个等待时间
            ::retryIfEmpty::
            if trans.getFluidInTank(sideInterface, 1).amount == 0 then      -- 流体不足 需要下单
                requestItem(database.get(1))
                if trans.getFluidInTank(sideInterface, 1).amount == 0 then  -- 防止一些问题 同时打印问题
                    goto retryIfEmpty
                    print("下单对应的流体数量可能太少了或者被动,导致获取不到对应流体")
                end
            end
 
            while fluidAmount > 0 do     -- 消耗流体
                if trans.getFluidInTank(sideInterface, 1).amount == 0 then goto retryIfEmpty end
                local a,b = trans.transferFluid(sideInterface, sideCacheBuffer, fluidAmount, 0)
                fluidAmount = fluidAmount - b
                os.sleep(0.25)
            end
            os.sleep(1)
            mei.setFluidInterfaceConfiguration(0)   -- 清除接口标记的流体
        end
 
        os.execute("cls")
        os.sleep(5)     -- 每轮结束的休息时间 默认5s 同时也用于机器的关机或者也可以关机oc(
 
        if not gtm.isWorkAllowed() then
            print("机器已关机,正在待机休眠中。。。。")
            while not gtm.isWorkAllowed() do
                os.sleep(10)
            end
        end
    end
    
end
 
main()
