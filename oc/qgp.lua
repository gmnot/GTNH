local os = require("os")
local component = require("component")
local sides = require("sides")

local trans = component.transposer
local sideCacheBuffer = sides.down
local sideAEInfusion = sides.north
local sideInterface = sides.east
local database = component.database
local mei = component.me_interface
local gtm = component.gt_machine

local cacheCount = 1
local cacheTable = {}
local cacheSourceTable = {}

local fcFluidDrop = "ae2fc:fluid_drop"

-- GT dust damage -> plasma material name, copied only from qgp2.9ref mapping.
local gtMaterial = {
    [382]="ardite",      [2884]="desh",        [2393]="oriharukon",  [2340]="meteoriciron", [2103]="americium",
    [2006]="lithium",    [2008]="beryllium",   [2010]="carbon",      [2017]="sodium",       [2018]="magnesium",
    [2019]="aluminium",  [2020]="silicon",     [2021]="phosphorus",  [2022]="sulfur",       [2025]="potassium",
    [2026]="calcium",    [2028]="titanium",    [2029]="vanadium",    [2031]="manganese",    [2032]="iron",
    [2033]="cobalt",     [2034]="nickel",      [2035]="copper",      [2036]="zinc",         [2037]="gallium",
    [2039]="arsenic",    [2043]="rubidium",    [2044]="strontium",   [2045]="yttrium",      [2047]="niobium",
    [2048]="molybdenum", [2052]="palladium",   [2054]="silver",      [2055]="cadmium",      [2056]="indium",
    [2057]="tin",        [2058]="antimony",    [2059]="tellurium",   [2062]="caesium",      [2063]="barium",
    [2064]="lanthanum",  [2065]="cerium",      [2066]="praseodymium",[2067]="neodymium",    [2068]="promethium",
    [2069]="samarium",   [2070]="europium",    [2071]="gadolinium",  [2072]="terbium",      [2073]="dysprosium",
    [2074]="holmium",    [2075]="erbium",      [2076]="thulium",     [2077]="ytterbium",    [2078]="lutetium",
    [2080]="tantalum",   [2081]="tungsten",    [2086]="gold",        [2097]="uranium235",   [2098]="uranium",
}

local bartMaterial = {
    [3]="zirconium",
    [30]="thorium232",
    [64]="ruthenium",
    [78]="rhodium",
    [11000]="hafnium",
    [11012]="iodine",
}

local function stackAmount(stack)
    return tonumber(stack and (stack.size or stack.amount or stack.count or stack.qty)) or 0
end

local function tankAmount(side, tank)
    local fluid = trans.getFluidInTank(side, tank)
    return tonumber(fluid and fluid.amount) or 0
end

local function normalizeMaterialName(materialName)
    materialName = tostring(materialName or "")
    materialName = materialName:gsub("^plasma%.", "")
    materialName = materialName:gsub("^molten%.", "")
    return materialName
end

local function recordSource(index, source)
    cacheSourceTable[index] = source
end

local function printSourceInfo(index)
    local source = cacheSourceTable[index]
    if source == nil then
        print(string.format("[source %d] none", index))
        return
    end

    print(string.format(
        "[source %d] kind=%s slot=%s name=%s label=%s damage=%s amount=%s material=%s method=%s",
        index,
        tostring(source.kind),
        tostring(source.slot),
        tostring(source.name),
        tostring(source.label),
        tostring(source.damage),
        tostring(source.amount),
        tostring(source.material),
        tostring(source.method)
    ))
end

local function setAE2FCPlasma(materialName)
    local material = normalizeMaterialName(materialName)
    database.set(cacheCount, fcFluidDrop, 0, "{Fluid:plasma." .. material .. "}")
    cacheCount = cacheCount + 1
end

local function addPlasmaDemand(materialName, amount, source)
    cacheTable[cacheCount] = amount
    source.material = normalizeMaterialName(materialName)
    recordSource(cacheCount, source)
    setAE2FCPlasma(materialName)
end

local function addItemDemand(item, slot)
    local amount = stackAmount(item) * 1296
    local materialName = nil
    local method = nil

    if item.name == "bartworks:gt.bwMetaGenerateddust" then
        materialName = bartMaterial[item.damage]
        method = "bartMaterial"
    elseif item.name ~= nil and item.name:match("^miscutils:itemDust") ~= nil then
        materialName = string.lower(string.match(item.name, "miscutils:itemDust(.+)$") or "")
        method = "miscutils"
    elseif item.name == "gregtech:gt.metaitem.01" then
        materialName = gtMaterial[item.damage]
        method = "gtMaterial"

        if materialName == nil then
            cacheTable[cacheCount] = amount
            recordSource(cacheCount, {
                kind = "item",
                slot = slot,
                name = item.name,
                label = item.label,
                damage = item.damage,
                amount = stackAmount(item),
                material = nil,
                method = "damage+29000",
            })
            database.set(cacheCount, "gregtech:gt.metaitem.01", 29000 + item.damage, "")
            cacheCount = cacheCount + 1
            return
        end
    end

    if materialName == nil or materialName == "" then
        print(string.format(
            "[scan bad] no mapping slot=%d name=%s label=%s damage=%s size=%s",
            slot,
            tostring(item.name),
            tostring(item.label),
            tostring(item.damage),
            tostring(stackAmount(item))
        ))
        return
    end

    addPlasmaDemand(materialName, amount, {
        kind = "item",
        slot = slot,
        name = item.name,
        label = item.label,
        damage = item.damage,
        amount = stackAmount(item),
        method = method,
    })
end

local function setDatabase()
    for i = 1, 7 do
        local fluid = trans.getFluidInTank(sideCacheBuffer, i)
        if fluid == nil or tankAmount(sideCacheBuffer, i) == 0 then break end

        addPlasmaDemand(fluid.name, tankAmount(sideCacheBuffer, i) * 1000, {
            kind = "fluid",
            slot = i,
            name = fluid.name,
            label = fluid.label,
            damage = nil,
            amount = tankAmount(sideCacheBuffer, i),
            method = "fluid",
        })
    end

    for i = 1, 7 do
        if cacheCount == 8 then break end
        local item = trans.getStackInSlot(sideCacheBuffer, i)
        if item ~= nil then
            addItemDemand(item, i)
        end
    end
end

local function isBadDatabaseStack(stack)
    if stack == nil then return true end
    local label = tostring(stack.label or "")
    local name = tostring(stack.name or "")
    if label == "" and name == "" then return true end
    if label:find("???", 1, true) ~= nil then return true end
    if name:find("???", 1, true) ~= nil then return true end
    return false
end

local function validateDatabase()
    local ok = true

    if #cacheTable ~= 7 then
        print(string.format("[scan bad] expected 7 entries, got %d", #cacheTable))
        ok = false
    end

    for i = 1, #cacheTable do
        local stack = database.get(i)
        if isBadDatabaseStack(stack) then
            print(string.format(
                "[scan bad] db=%d label=%s name=%s damage=%s amount=%s need=%s",
                i,
                tostring(stack and stack.label),
                tostring(stack and stack.name),
                tostring(stack and stack.damage),
                tostring(stack and (stack.size or stack.amount)),
                tostring(cacheTable[i])
            ))
            printSourceInfo(i)
            ok = false
        else
            print(string.format("[scan ok] db=%d label=%s need=%s", i, tostring(stack.label), tostring(cacheTable[i])))
        end
    end

    return ok
end

local function clearCacheBuffer()
    for i = 1, 7 do
        local amount = tankAmount(sideCacheBuffer, i)
        if amount == 0 then break end
        trans.transferFluid(sideCacheBuffer, sideAEInfusion, amount, i - 1)
    end

    for i = 1, 7 do
        local item = trans.getStackInSlot(sideCacheBuffer, i)
        if item ~= nil then
            trans.transferItem(sideCacheBuffer, sideAEInfusion, stackAmount(item), i)
        end
    end
end

local function requestItem(item)
    if item.name == "gregtech:gt.metaitem.01" and item.fluid ~= nil then
        database.set(10, fcFluidDrop, 0, "{Fluid:" .. item.fluid.name .. "}")
        item = database.get(10)
    end

    local printedMissing = false
    local failureCount = 0

    ::retryRequest::
    local craftable = mei.getCraftables({name=item.name, label=item.label})[1]

    if tankAmount(sideInterface, 1) >= 8000 then return end

    if not craftable then
        if not printedMissing then
            printedMissing = true
            print("no craftable drop: " .. tostring(item.label) .. "; waiting")
        end
        os.sleep(5)
        goto retryRequest
    end

    local result = craftable.request(1, true)
    printedMissing = false
    print("requested: " .. tostring(item.label))
    os.sleep(2)

    if result.hasFailed() or result.isCanceled() then
        print("request failed, retry in 5s")
        failureCount = failureCount + 1
        if failureCount >= 12 then
            os.sleep(20)
            if failureCount > 15 then
                print("serious request issue; manual maintenance needed")
                while true do os.sleep(5) end
            end

            local cpus = mei.getCpus()
            for i = 1, #cpus do
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

local function processFluid()
    for i = 1, 7 do
        mei.setFluidInterfaceConfiguration(0, database.address, i)
        os.sleep(0.15)

        ::retryIfEmpty::
        if tankAmount(sideInterface, 1) == 0 then
            requestItem(database.get(i))
            if tankAmount(sideInterface, 1) == 0 then
                print("[transfer] interface empty after request; retry")
                goto retryIfEmpty
            end
        end

        while cacheTable[i] > 0 do
            if tankAmount(sideInterface, 1) == 0 then goto retryIfEmpty end
            local _, moved = trans.transferFluid(sideInterface, sideCacheBuffer, cacheTable[i], 0)
            moved = tonumber(moved) or 0
            cacheTable[i] = cacheTable[i] - moved
            os.sleep(0.35)
        end
    end
    mei.setFluidInterfaceConfiguration(0)
end

local function clearResidualPlasma()
    for i = 1, 7 do
        local fluid = trans.getFluidInTank(sideCacheBuffer, i)
        if fluid ~= nil and tankAmount(sideCacheBuffer, i) > 0 and tostring(fluid.name or ""):match("^plasma%.") then
            trans.transferFluid(sideCacheBuffer, sideAEInfusion, tankAmount(sideCacheBuffer, i), i - 1)
            print("clear residual plasma: " .. tostring(fluid.name) .. " " .. tostring(tankAmount(sideCacheBuffer, i)) .. "mB")
        end
    end
end

local function waitForMachineAndClearPlasma()
    print("waiting for machine to start")
    local timeout = 0
    local maxWait = 60

    while gtm.getWorkProgress() <= 0 do
        os.sleep(0.5)
        timeout = timeout + 0.5
        if timeout >= maxWait then
            print("machine start timeout; skip residual cleanup")
            return
        end
    end

    print("machine started; clear residual plasma")
    clearResidualPlasma()
end

local function printFluidInfo()
    for i = 1, #cacheTable do
        local stack = database.get(i)
        print(tostring(stack and stack.label), cacheTable[i])
    end
end

local function main()
    while true do
        cacheCount = 1
        cacheTable = {}
        cacheSourceTable = {}

        local fluid = trans.getFluidInTank(sideCacheBuffer, 1)
        if fluid ~= nil and tankAmount(sideCacheBuffer, 1) <= 64 then
            print("init database")
            setDatabase()

            if validateDatabase() then
                print("all inputs valid; moving inputs and processing plasma")
                printFluidInfo()
                clearCacheBuffer()
                processFluid()
                waitForMachineAndClearPlasma()
            else
                print("[scan bad] input not moved; fix mapping/input and rerun")
            end
        end

        os.sleep(5)

        if not gtm.isWorkAllowed() then
            print("machine disabled; waiting")
            while not gtm.isWorkAllowed() do
                os.sleep(10)
            end
        end
    end
end

main()
