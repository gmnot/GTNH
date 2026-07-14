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

function describeItem(item)
    if item == nil then return "nil" end
    return string.format(
        "%s | name=%s damage=%s size=%s",
        tostring(item.label or "unknown"),
        tostring(item.name or "unknown"),
        tostring(item.damage or "nil"),
        tostring(item.size or "nil")
    )
end

function tankAmount(side, tank)
    local info = trans.getFluidInTank(side, tank)
    if info == nil then return 0 end
    return tonumber(info.amount) or 0
end
 
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
    local cycle = 0

    while true do
        local item = trans.getStackInSlot(sideCacheBuffer, 1)

        if item ~= nil then
            cycle = cycle + 1
            print(string.format("[cycle %d] item: %s", cycle, describeItem(item)))
            print("[cycle " .. tostring(cycle) .. "] init database")

            local tank1Amount = tankAmount(sideCacheBuffer, 1)
            local tank2Amount = tankAmount(sideCacheBuffer, 2)
            local fluidAmount = math.abs(tank1Amount - tank2Amount) * 144
            local initialFluidAmount = fluidAmount

            local materialName
            if item.name:match("miscutils:itemDust*") ~= nil then
                materialName = string.lower(string.match(item.name, "miscutils:itemDust" .. "(%w+)$"))
            else
                materialName = string.lower(GTMaterial[item.damage])
            end

            print(string.format(
                "[cycle %d] material=%s, tank1=%s, tank2=%s, transfer_total=%s",
                cycle,
                tostring(materialName),
                tostring(tank1Amount),
                tostring(tank2Amount),
                tostring(initialFluidAmount)
            ))

            setAE2FCPlasma(materialName)
            clearCacheBuffer()
            os.sleep(0.25)

            print("[cycle " .. tostring(cycle) .. "] start plasma transfer")
            mei.setFluidInterfaceConfiguration(0, database.address, 1)
            os.sleep(0.25)

            ::retryIfEmpty::
            if tankAmount(sideInterface, 1) == 0 then
                requestItem(database.get(1))
                if tankAmount(sideInterface, 1) == 0 then
                    print("[cycle " .. tostring(cycle) .. "] fluid still empty after request, retry")
                    goto retryIfEmpty
                end
            end

            while fluidAmount > 0 do
                local available = tankAmount(sideInterface, 1)
                if available == 0 then
                    print("[cycle " .. tostring(cycle) .. "] interface empty, retry request")
                    goto retryIfEmpty
                end

                local requested = fluidAmount
                print(string.format(
                    "[cycle %d] transfer request=%s available=%s remaining_before=%s",
                    cycle,
                    tostring(requested),
                    tostring(available),
                    tostring(fluidAmount)
                ))

                local _, moved = trans.transferFluid(sideInterface, sideCacheBuffer, requested, 0)
                moved = tonumber(moved) or 0
                fluidAmount = fluidAmount - moved
                print(string.format(
                    "[cycle %d] transferred=%s remaining_after=%s",
                    cycle,
                    tostring(moved),
                    tostring(fluidAmount)
                ))

                os.sleep(0.25)
            end

            print(string.format("[cycle %d] done total=%s", cycle, tostring(initialFluidAmount)))
            os.sleep(1)
            mei.setFluidInterfaceConfiguration(0)
        end

        os.sleep(5)

        if not gtm.isWorkAllowed() then
            print("[idle] machine disabled, waiting")
            while not gtm.isWorkAllowed() do
                os.sleep(10)
            end
            print("[idle] machine enabled, resume")
        end
    end
end

main()
