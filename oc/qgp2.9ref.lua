local os = require("os")
local component = require("component")
local sides = require("sides")
 
local trans = component.transposer
local fInterface = component.fluid_interface
local gtm = component.gt_machine
 
local sideCacheBuffer = sides.west        -- 转运器对应的 大型原料缓存仓
local sideAEInfusion = sides.south        -- 转运器对应的 ae的物质聚合器
local sideInterface = sides.down          -- 转运器对应的 主网也是唯一的ae接口 用于设置流体的输出
 
-- BartWorks 特殊材料映射 (damage -> 材料名)
local bartMaterial = {
    [3]="zirconium", [30]="thorium232", [64]="ruthenium", [78]="rhodium", [11000]="hafnium", [11012]="iodine" -- 锆 钍232 钌 铑 铪 碘
}
 
-- GT标准粉中，等离子体名无法从label推导的特例（damage → 等离子体名，不含 "plasma."）
local gtDustPlasmaOverride = {
    [382] ="ardite",      [2884]="desh",        [2393]="oriharukon",  [2340]="meteoriciron", [2103]="americium",   -- 阿迪特 戴斯 奥利哈钢 陨铁 镅
    [2006]="lithium",     [2008]="beryllium",   [2010]="carbon",      [2017]="sodium",       [2018]="magnesium",   -- 锂 铍 碳 钠 镁
    [2019]="aluminium",   [2020]="silicon",     [2021]="phosphorus",  [2022]="sulfur",       [2025]="potassium",   -- 铝 硅 磷 硫 钾
    [2026]="calcium",     [2028]="titanium",    [2029]="vanadium",    [2031]="manganese",    [2032]="iron",        -- 钙 钛 钒 锰 铁
    [2033]="cobalt",      [2034]="nickel",      [2035]="copper",      [2036]="zinc",         [2037]="gallium",     -- 钴 镍 铜 锌 镓
    [2039]="arsenic",     [2043]="rubidium",    [2044]="strontium",   [2045]="yttrium",      [2047]="niobium",     -- 砷 铷 锶 钇 铌
    [2048]="molybdenum",  [2052]="palladium",   [2054]="silver",      [2055]="cadmium",      [2056]="indium",      -- 钼 钯 银 镉 铟
    [2057]="tin",         [2058]="antimony",    [2059]="tellurium",   [2062]="caesium",      [2063]="barium",      -- 锡 锑 碲 铯 钡
    [2064]="lanthanum",   [2065]="cerium",      [2066]="praseodymium",[2067]="neodymium",    [2068]="promethium",  -- 镧 铈 镨 钕 钷
    [2069]="samarium",    [2070]="europium",    [2071]="gadolinium",  [2072]="terbium",      [2073]="dysprosium",  -- 钐 铕 钆 铽 镝
    [2074]="holmium",     [2075]="erbium",      [2076]="thulium",     [2077]="ytterbium",    [2078]="lutetium",    -- 钬 铒 铥 镱 镥
    [2080]="tantalum",    [2081]="tungsten",    [2086]="gold",        [2097]="uranium235",   [2098]="uranium"      -- 钽 钨 金 铀235 铀
}
 
local plasmaDemands = {}
function scanCacheBuffer()
    plasmaDemands = {}
    local function fluidToPlasma(fluidName)
        if fluidName:match("^molten%.") then
            return "plasma." .. fluidName:match("^molten%.(.+)$")
        end
        return "plasma." .. fluidName
    end
 
    -- 扫描流体槽
    for i = 1, 7 do
        local fluid = trans.getFluidInTank(sideCacheBuffer, i)
        if not fluid or fluid.amount == 0 then break end
 
        if fluid.name:match("^plasma%.") then
            trans.transferFluid(sideCacheBuffer, sideAEInfusion, fluid.amount, i - 1)
            print("跳过等离子体 " .. fluid.name .. "，已移入聚合器")
            goto nextFluid
        end
 
        local plasmaName = fluidToPlasma(fluid.name)
        local amount = fluid.amount * 1000
        table.insert(plasmaDemands, {name = plasmaName, amount = amount})
        print(string.format("流体 %s → %s * %d mB", fluid.label or fluid.name, plasmaName, amount))
        ::nextFluid::
    end
 
    -- 扫描物品槽（粉）
    for i = 1, 7 do
        local item = trans.getStackInSlot(sideCacheBuffer, i)
        if not item then break end
 
        local plasmaName, amount = nil, item.size * 1296
 
        if item.name == "gregtech:gt.metaitem.01" then
            local override = gtDustPlasmaOverride[item.damage]
            if override then
                plasmaName = "plasma." .. override
            else
                local label = item.label or ""
                local mat = label:match("^(.+) Dust$")
                if mat then
                    plasmaName = "plasma." .. string.lower(mat:gsub(" ", ""))
                else
                    print("警告：无法从 label '" .. label .. "' 提取材料名，跳过")
                    goto nextItem
                end
            end
        elseif item.name == "bartworks:gt.bwMetaGenerateddust" then
            local mat = bartMaterial[item.damage]
            if mat then
                plasmaName = "plasma." .. mat
            else
                print("警告：未知 BartWorks 材料 damage=" .. item.damage .. "，跳过")
                goto nextItem
            end
        elseif item.name:match("^miscutils:itemDust") then
            local mat = string.lower(string.match(item.name, "miscutils:itemDust(.+)$"))
            plasmaName = "plasma." .. mat
        else
            print("警告：未知物品 " .. (item.label or item.name) .. "，跳过")
            goto nextItem
        end
 
        table.insert(plasmaDemands, {name = plasmaName, amount = amount})
        print(string.format("物品 %s → %s × %d mB", item.label, plasmaName, amount))
        ::nextItem::
    end
end
 
function clearCacheBuffer()
    for i = 1, 7 do
        local f = trans.getFluidInTank(sideCacheBuffer, i)
        if f and f.amount > 0 then
            trans.transferFluid(sideCacheBuffer, sideAEInfusion, f.amount, i - 1)
        end
    end
    for i = 1, 7 do
        local it = trans.getStackInSlot(sideCacheBuffer, i)
        if it then
            trans.transferItem(sideCacheBuffer, sideAEInfusion, it.size, i)
        end
    end
end
 
local function findRequest(t, depth)
    if depth > 3 then return nil end
    if type(t) == "table" then
        if t.request ~= nil then return t end
        for _, v in pairs(t) do
            local found = findRequest(v, depth + 1)
            if found then return found end
        end
    end
end
 
function requestPlasmaSynthesis(plasmaName)
    pcall(function()
        fInterface.setFluidInterfaceConfiguration(0, {name = plasmaName})
    end)
    os.sleep(0.5)
 
    local ok, craftables = pcall(function()
        return {fInterface.getCraftables({name = plasmaName})}
    end)
    if not ok or #craftables == 0 then
        ok, craftables = pcall(function()
            return {fInterface.getCraftables()}
        end)
        if not ok or #craftables == 0 then
            print("[下单] 未找到可合成项: " .. plasmaName)
            return false
        end
    end
 
    local obj = findRequest(craftables, 1)
    if not obj then
        print("[下单] 未找到请求对象: " .. plasmaName)
        return false
    end
 
    local callOk, status = pcall(function()
        return obj.request(1, true)
    end)
    if not callOk then
        print("[下单] 调用 request 失败: " .. tostring(status))
        return false
    end
 
    if type(status) == "table" and status.hasFailed and not status.hasFailed() then
        print("[下单] 已提交合成: " .. plasmaName)
        return true
    else
        print("[下单] 合成提交失败: " .. plasmaName)
        return false
    end
end
 
function safeSetFilter(fluidName)
    local ok, err = pcall(function()
        fInterface.setFluidInterfaceConfiguration(0, {name = fluidName})
    end)
    if not ok then
        print("  [过滤器] 设置失败: " .. fluidName .. " (" .. tostring(err) .. ")")
        return false
    end
    return true
end
 
-- 仅清除接口过滤器，不等待
local function clearFilterOnly()
    pcall(function()
        fInterface.setFluidInterfaceConfiguration(0)
    end)
end
 
-- 清除接口过滤器并等待2秒，让流体返回网络
local function clearFilterAndWait()
    clearFilterOnly()
    os.sleep(2)
end
 
local function isCraftRunning(status)
    if not status then
        return false
    end
 
    local done = false
    local failed = false
 
    pcall(function()
        done = status.isDone()
    end)
 
    pcall(function()
        failed = status.hasFailed()
    end)
 
    return (not done and not failed)
end
 
function processPlasmaDemands()
    for i, demand in ipairs(plasmaDemands) do
        print(string.format(">>> %d/%d: %s, 需要 %d mB", i, #plasmaDemands, demand.name, demand.amount))
 
        if not safeSetFilter(demand.name) then
            clearFilterOnly()
            goto nextDemand
        end
        os.sleep(0.3)
 
        local remaining = demand.amount
        local orderAttempted = false
        local waitCount = 0
        local craftStatus = nil
 
        while remaining > 0 do
            local ifFluid = trans.getFluidInTank(sideInterface, 1)
            local available = ifFluid and ifFluid.amount or 0
 
            if available > 0 then
                local take = math.min(remaining, available)
                local _, moved = trans.transferFluid(sideInterface, sideCacheBuffer, take, 0)
 
                if moved > 0 then
                    remaining = remaining - moved
                    waitCount = 0
 
                    print(string.format(
                        "已抽取 %d mB,剩余需求 %d mB",
                        moved,
                        remaining
                    ))
 
                    os.sleep(0.1)
                else
                    os.sleep(0.5)
                end
 
            else
                if not orderAttempted then
                    print("接口无流体，尝试下单...")
 
                    craftStatus = requestPlasmaSynthesis(demand.name)
 
                    orderAttempted = true
                    waitCount = 0
 
                else
                    waitCount = waitCount + 1
 
                    if waitCount >= 10 then
 
                        if isCraftRunning(craftStatus) then
                            print("合成任务仍在运行...")
                        else
                            print("等待超时，重新下单...")
                            craftStatus = requestPlasmaSynthesis(demand.name)
                        end
 
                        waitCount = 0
 
                    else
                        print(string.format(
                            "等待合成完成(已尝试过下单 %d/10)...",
                            waitCount
                        ))
                    end
                end
 
                os.sleep(5)
            end
        end
 
        print(demand.name .. "输入完成")
        clearFilterOnly()
 
        ::nextDemand::
    end
 
    print("本轮等离子体输入完成")
    clearFilterAndWait()
end
 
-- 主循环
function main()
    if not gtm then
        print("注意: gt_machine 组件未找到，将跳过机器休眠检测")
    end
    if not fInterface then
        print("错误: fluid_interface 组件未找到，无法运行！")
        return
    end
 
    while true do
        local firstFluid = trans.getFluidInTank(sideCacheBuffer, 1)
        local amount = firstFluid and firstFluid.amount or 0
 
        if amount <= 64 then
            os.execute("cls")
            print("\n=== 检测到新一批原料 ===")
            scanCacheBuffer()
            if #plasmaDemands > 0 then
                clearCacheBuffer()
                processPlasmaDemands()
            else
                print("无有效原料")
                clearFilterOnly()
            end
        end
 
        if gtm then
            if not gtm.isWorkAllowed() then
                print("机器已关机，休眠中...")
                while not gtm.isWorkAllowed() do
                    os.sleep(10)
                end
                print("机器已启动")
            end
        end
 
        os.sleep(5)
    end
end
 
main()
