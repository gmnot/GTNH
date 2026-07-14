local os = require("os")
local component = require("component")
local sides = require("sides")
 
local trans = component.transposer
local sideCacheBuffer = sides.down       -- 转运器对应的 大型原料缓存仓
local sideAEInfusion = sides.north       -- 转运器对应的 ae的物质聚合器
local sideInterface = sides.east         -- 转运器对应的 主网也是是唯一的ae接口 用于设置流体的输出
local database = component.database
local mei = component.me_interface
 
local gtm = component.gt_machine        -- 在me接口旁边的适配器放入的 mfu 检查聚变异化器这个机器的状态 关机就不执行相关运行逻辑 即 休眠
 
local cacheCount = 1
local cacheTable = {}
 
local fcFluidDrop = "ae2fc:fluid_drop"
local bartMaterial = {
    [3]="zirconium",
    [30]="thorium232",
    [64]="ruthenium",
    [78]="rhodium",
    [11000]="hafnium",
    [11012]="iodine"}  -- bart材料对应的等离子 分别是 锆 钍-232 钌 铑 铪 碘
 
function setAE2FCPlasma(materialName)    
    database.set( cacheCount, fcFluidDrop, 0, "{Fluid:plasma." .. materialName .. "}")
    cacheCount = cacheCount + 1
end
 
function setDatabase()
    for i=1,7 do        -- 先遍历获取 流体对应的等离子 并将其存储在数据库
        local fluid = trans.getFluidInTank(sideCacheBuffer,i)
        if fluid.amount == 0 then break end       -- 流体检测完毕 直接提前跳出循环
        cacheTable[cacheCount] = fluid.amount * 1000
        setAE2FCPlasma(fluid.name)          -- 把等离子对应的 ae2fc液滴 写入数据库
    end
 
    for i=1,7 do
        if cacheCount == 8 then break end   -- 已经获取完毕 7种等离子 重置缓存同时跳出循环
        local item = trans.getStackInSlot(sideCacheBuffer, i)
        if item == nil then goto ContinueEnd end
        cacheTable[cacheCount] = item.size * 1296    -- 设置数量
        local materialName
        if item.name == "bartworks:gt.bwMetaGenerateddust" then     -- 特殊处理bart的材料系统生成的粉对应的GT++等离子
            materialName = bartMaterial[item.damage]
        elseif item.name:match("miscutils:itemDust*") ~= nil then   -- 对于GT++的材料进行处理 直接生成对应的液滴
            materialName = string.lower(string.match(item.name, "miscutils:itemDust" .. "(%w+)$"))
        elseif item.name == "gregtech:gt.metaitem.01" then              -- 对于GT材料系统生成的材料使用对应的的等离子单元进行标记
                                                                        -- 有对应的特征 粉的metaID + 29000 对应的物品就是等离子单元
            if item.damage == 382 then
                materialName = "ardite"        -- 由于阿迪特等离子单元比较特殊 故 需要特殊处理
            else
                database.set(cacheCount, "gregtech:gt.metaitem.01", 29000 + item.damage, "")
                cacheCount = cacheCount + 1
            end
        end
        if materialName ~= nil then setAE2FCPlasma(materialName) end
        ::ContinueEnd::
    end
 
end
 
function clearCacheBuffer()
 
    local counter = 1
 
    for i=1,7 do        -- 先清除材料缓存器中的流体 之后用于存储需要精确输入的原料
        local fluid = trans.getFluidInTank(sideCacheBuffer, i)
        if fluid.amount == 0 then break end     -- 已经没有流体了 就退出循环
        trans.transferFluid(sideCacheBuffer, sideAEInfusion, fluid.amount, i - 1)     -- 不考虑是否正确是输出流体 因为没必要
        counter = counter + 1
    end
 
    for i=1,7 do
        if counter == 8 then break end          -- 已经没有物品了 退出循环
        local item = trans.getStackInSlot(sideCacheBuffer, i)
        trans.transferItem(sideCacheBuffer, sideAEInfusion, item.size, i)
        counter = counter + 1
    end
 
end
 
function requestItem(item)
 
    if item.name == "gregtech:gt.metaitem.01" then  -- 对于单元类的物品 需要下单的是液滴 需要转换一下
        database.set( 10, fcFluidDrop, 0, "{Fluid:" .. item.fluid.name .. "}")      -- 在数据库10号位置设置缓存 下单液体对应液滴
        item = database.get(10)
    end
 
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
 
function processFluid()
    for i=1,7 do       -- 处理 ae相关流体的发配
        mei.setFluidInterfaceConfiguration(0, database.address, i)
        os.sleep(0.15)      -- 需要一个缓冲的时间 用于ae补充标记的流体
        ::retryIfEmpty::
        if trans.getFluidInTank(sideInterface, 1).amount == 0 then       -- 流体不足 需要下单
            requestItem(database.get(i))
            if trans.getFluidInTank(sideInterface, 1).amount == 0 then  -- 防止一些问题 同时打印问题
                goto retryIfEmpty
                print("下单对应的流体数量可能太少了或者被动,导致获取不到对应流体")
            end    
        end
        while cacheTable[i] > 0 do     -- 消耗流体
            if trans.getFluidInTank(sideInterface, 1).amount == 0 then goto retryIfEmpty end
            local a,b = trans.transferFluid(sideInterface, sideCacheBuffer, cacheTable[i], 0)
            cacheTable[i] = cacheTable[i] - b
            os.sleep(0.35)
        end
    end
    mei.setFluidInterfaceConfiguration(0)       -- 将接口的流体设置为空
end
 
-- 新增：清理缓存仓中残留的等离子体，防止下一轮原料堵塞
function clearResidualPlasma()
    for i=1,7 do
        local fluid = trans.getFluidInTank(sideCacheBuffer, i)
        if fluid.amount > 0 and fluid.name:match("^plasma%.") then
            trans.transferFluid(sideCacheBuffer, sideAEInfusion, fluid.amount, i - 1)
            print("清理残留等离子体: " .. fluid.name .. " " .. fluid.amount .. "mB")
        end
    end
end
 
-- 新增：等待机器开始配方处理，然后清理残留等离子体
function waitForMachineAndClearPlasma()
    print("等待机器开始处理...")
    local timeout = 0
    local maxWait = 60  -- 最大等待60秒，防止无限阻塞
    
    -- 轮询检测机器是否开始工作（getWorkProgress > 0 表示有配方在执行）
    while gtm.getWorkProgress() <= 0 do
        os.sleep(0.5)
        timeout = timeout + 0.5
        if timeout >= maxWait then
            print("等待超时，机器未开始处理，跳过清理")
            return
        end
    end
    
    print("机器已开始处理，清理残留等离子体...")
    clearResidualPlasma()
end
 
function printFluidInfo()
    for i=1,#cacheTable do
        print(database.get(i).label,cacheTable[i])
    end
end
 
function main()
 
    os.execute("cls")
 
    while true do
        cacheCount = 1
        cacheTable = {}
 
        local fluid = trans.getFluidInTank(sideCacheBuffer, 1)
 
        if fluid.amount <= 64 then
 
            print("即将执行数据库初始化。。。")
            setDatabase()
 
            local shouldProcess = true
            if #cacheTable ~= 7 then    -- 检验并确认是否应该执行处理流体
                shouldProcess = false
            else
                for i=1,#cacheTable do              
                    if cacheTable[i] == nil then
                        shouldProcess = false
                        break
                    end
                end
            end
 
            if shouldProcess then
                print("即将执行等离子的处理操作。。。")
                printFluidInfo()        -- 输出 需要操作的等离子数量和名称
                clearCacheBuffer()      -- 清除 原材料缓存器
                processFluid()          -- 向机器输入所有所需流体
                
                -- 新增：输入完成后，等待机器开始处理，然后清理残留等离子体
                -- 确保下一轮原料不会被堵塞
                waitForMachineAndClearPlasma()
            end
 
        end
 
        os.execute("cls")
        os.sleep(5)
 
        if not gtm.isWorkAllowed() then
            print("机器已关机,正在待机休眠中。。。。")
            while not gtm.isWorkAllowed() do
                os.sleep(10)
            end
        end
        
    end
 
end
 
main()
