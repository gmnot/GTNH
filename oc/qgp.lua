local os = require("os")
local component = require("component")
local sides = require("sides")
local filesystem = require("filesystem")
local serialization = require("serialization")

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
local demandTable = {}

local statePath = "/home/qgp.state"
local stateBackupPath = statePath .. ".bak"
local stateTempPath = statePath .. ".tmp"
local activeTask = nil
local orphanPlasmaWarned = false

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

local function tankFluid(side, tank)
    local fluid = trans.getFluidInTank(side, tank)
    if fluid == nil or (tonumber(fluid.amount) or 0) <= 0 then return nil end
    return fluid
end

local function writeStateFile(path, value)
    local file, err = io.open(path, "w")
    if file == nil then return false, err end
    local ok, serialized = pcall(serialization.serialize, value)
    if not ok then
        file:close()
        return false, serialized
    end
    local wrote, writeErr = file:write(serialized)
    file:close()
    if wrote == nil then return false, writeErr end
    return true
end

local function saveTask()
    if activeTask == nil then return true end
    activeTask.updatedAt = os.time()
    local ok, err = writeStateFile(stateTempPath, activeTask)
    if not ok then
        print("[state] cannot write journal: " .. tostring(err))
        return false
    end

    if filesystem.exists(statePath) then
        if filesystem.exists(stateBackupPath) then filesystem.remove(stateBackupPath) end
        local backedUp, backupErr = filesystem.rename(statePath, stateBackupPath)
        if not backedUp then
            print("[state] cannot rotate journal: " .. tostring(backupErr))
            return false
        end
    end
    local renamed, renameErr = filesystem.rename(stateTempPath, statePath)
    if not renamed then
        print("[state] cannot commit journal: " .. tostring(renameErr))
        return false
    end
    return true
end

local function readStateFile(path)
    local file = io.open(path, "r")
    if file == nil then return nil end
    local contents = file:read("*a")
    file:close()
    local ok, value = pcall(serialization.unserialize, contents)
    if not ok or type(value) ~= "table" or value.version ~= 1 or type(value.demands) ~= "table" then
        return nil
    end
    if value.phase ~= "prepared" and value.phase ~= "transferring" and value.phase ~= "waiting" and value.phase ~= "cleanup" then
        return nil
    end
    for _, demand in ipairs(value.demands) do
        if type(demand.amount) ~= "number" or type(demand.remaining) ~= "number" or
           type(demand.fluidName) ~= "string" or type(demand.dbName) ~= "string" then
            return nil
        end
    end
    return value
end

local function loadTask()
    local task = readStateFile(statePath)
    if task ~= nil then return task end
    task = readStateFile(stateBackupPath)
    if task ~= nil then print("[state] primary journal invalid; recovered backup") end
    return task
end

local function clearTask()
    activeTask = nil
    if filesystem.exists(statePath) then filesystem.remove(statePath) end
    if filesystem.exists(stateBackupPath) then filesystem.remove(stateBackupPath) end
    if filesystem.exists(stateTempPath) then filesystem.remove(stateTempPath) end
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
    demandTable[cacheCount] = {
        amount = amount,
        remaining = amount,
        fluidName = "plasma." .. source.material,
        dbName = fcFluidDrop,
        dbDamage = 0,
        dbNbt = "{Fluid:plasma." .. source.material .. "}",
    }
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
            demandTable[cacheCount] = {
                amount = amount,
                remaining = amount,
                dbName = "gregtech:gt.metaitem.01",
                dbDamage = 29000 + item.damage,
                dbNbt = "",
            }
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
            if demandTable[i] ~= nil and demandTable[i].fluidName == nil and stack.fluid ~= nil then
                demandTable[i].fluidName = stack.fluid.name
            end
            print(string.format("[scan ok] db=%d label=%s need=%s", i, tostring(stack.label), tostring(cacheTable[i])))
        end
        if demandTable[i] == nil or demandTable[i].fluidName == nil then
            print(string.format("[scan bad] db=%d cannot determine target fluid", i))
            ok = false
        end
    end

    return ok
end

local function clearCacheBuffer()
    for i = 1, 7 do
        local amount = tankAmount(sideCacheBuffer, i)
        if amount > 0 then
            trans.transferFluid(sideCacheBuffer, sideAEInfusion, amount, i - 1)
        end
    end

    for i = 1, 7 do
        local item = trans.getStackInSlot(sideCacheBuffer, i)
        if item ~= nil then
            trans.transferItem(sideCacheBuffer, sideAEInfusion, stackAmount(item), i)
        end
    end

    for i = 1, 7 do
        if tankAmount(sideCacheBuffer, i) > 0 or trans.getStackInSlot(sideCacheBuffer, i) ~= nil then
            print("[clear] inputs remain in cache; will retry")
            return false
        end
    end
    return true
end

local function requestItem(item, expectedFluidName)
    if item.name == "gregtech:gt.metaitem.01" and item.fluid ~= nil then
        database.set(10, fcFluidDrop, 0, "{Fluid:" .. item.fluid.name .. "}")
        item = database.get(10)
    end

    local printedMissing = false
    local failureCount = 0

    ::retryRequest::
    local craftable = mei.getCraftables({name=item.name, label=item.label})[1]

    local interfaceFluid = tankFluid(sideInterface, 1)
    if interfaceFluid ~= nil and interfaceFluid.name == expectedFluidName and interfaceFluid.amount >= 8000 then return end

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

local function restoreDatabase(demands)
    for i, demand in ipairs(demands) do
        database.set(i, demand.dbName, demand.dbDamage, demand.dbNbt)
    end
end

local function fluidAmountsInCache()
    local amounts = {}
    for i = 1, 7 do
        local fluid = tankFluid(sideCacheBuffer, i)
        if fluid ~= nil then
            amounts[fluid.name] = (amounts[fluid.name] or 0) + fluid.amount
        end
    end
    return amounts
end

local function reconcileProgress(demands)
    local available = fluidAmountsInCache()
    for _, demand in ipairs(demands) do
        local observed = math.min(demand.amount, available[demand.fluidName] or 0)
        available[demand.fluidName] = (available[demand.fluidName] or 0) - observed
        local recorded = demand.amount - (tonumber(demand.remaining) or demand.amount)
        demand.remaining = demand.amount - math.max(recorded, observed)
    end
end

local function setInterfaceFluid(index, expectedFluidName)
    mei.setFluidInterfaceConfiguration(0)
    os.sleep(0.5)

    local waited = 0
    local fluid = tankFluid(sideInterface, 1)
    while fluid ~= nil and fluid.name ~= expectedFluidName do
        if waited == 0 then
            print("[transfer] draining stale interface fluid: " .. tostring(fluid.name))
        end
        os.sleep(0.5)
        waited = waited + 0.5
        if waited >= 10 then
            print("[transfer] stale interface fluid did not drain; retrying filter reset")
            mei.setFluidInterfaceConfiguration(0)
            waited = 0
        end
        fluid = tankFluid(sideInterface, 1)
    end

    mei.setFluidInterfaceConfiguration(0, database.address, index)
    os.sleep(0.5)
end

local function processFluid(demands)
    reconcileProgress(demands)
    if not saveTask() then error("cannot persist reconciled progress") end

    for i, demand in ipairs(demands) do
        if demand.remaining > 0 then
            print(string.format(
                "[transfer] %d/%d fluid=%s remaining=%d/%d mB",
                i, #demands, demand.fluidName, demand.remaining, demand.amount
            ))
            setInterfaceFluid(i, demand.fluidName)

            ::retryIfEmpty::
            local interfaceFluid = tankFluid(sideInterface, 1)
            if interfaceFluid ~= nil and interfaceFluid.name ~= demand.fluidName then
                print(string.format("[transfer] wrong fluid: expected=%s actual=%s; not moving", demand.fluidName, tostring(interfaceFluid.name)))
                setInterfaceFluid(i, demand.fluidName)
                goto retryIfEmpty
            end

            if interfaceFluid == nil then
                requestItem(database.get(i), demand.fluidName)
                interfaceFluid = tankFluid(sideInterface, 1)
                if interfaceFluid == nil then
                    print("[transfer] interface empty after request; retry")
                    goto retryIfEmpty
                end
                if interfaceFluid.name ~= demand.fluidName then
                    print(string.format("[transfer] request returned wrong fluid: expected=%s actual=%s", demand.fluidName, tostring(interfaceFluid.name)))
                    setInterfaceFluid(i, demand.fluidName)
                    goto retryIfEmpty
                end
            end

            while demand.remaining > 0 do
                if tankAmount(sideInterface, 1) == 0 then goto retryIfEmpty end
                interfaceFluid = tankFluid(sideInterface, 1)
                if interfaceFluid == nil or interfaceFluid.name ~= demand.fluidName then
                    print("[transfer] interface changed unexpectedly; resetting filter")
                    setInterfaceFluid(i, demand.fluidName)
                    goto retryIfEmpty
                end
                local _, moved = trans.transferFluid(sideInterface, sideCacheBuffer, demand.remaining, 0)
                moved = tonumber(moved) or 0
                if moved > 0 then
                    demand.remaining = demand.remaining - moved
                    cacheTable[i] = demand.remaining
                    if not saveTask() then error("cannot persist transfer progress") end
                end
                os.sleep(0.1)
            end
        end
    end
    mei.setFluidInterfaceConfiguration(0)
end

local function clearResidualPlasma()
    for i = 1, 7 do
        local fluid = trans.getFluidInTank(sideCacheBuffer, i)
        if fluid ~= nil and tankAmount(sideCacheBuffer, i) > 0 and tostring(fluid.name or ""):match("^plasma%.") then
            local amount = tankAmount(sideCacheBuffer, i)
            trans.transferFluid(sideCacheBuffer, sideAEInfusion, amount, i - 1)
            print("clear residual plasma: " .. tostring(fluid.name) .. " " .. tostring(amount) .. "mB")
        end
    end
    for i = 1, 7 do
        local fluid = tankFluid(sideCacheBuffer, i)
        if fluid ~= nil and tostring(fluid.name or ""):match("^plasma%.") then
            print("[cleanup] residual plasma remains; will retry")
            return false
        end
    end
    return true
end

local function hasDemandFluid(demands)
    local amounts = fluidAmountsInCache()
    for _, demand in ipairs(demands) do
        if (amounts[demand.fluidName] or 0) > 0 then return true end
    end
    return false
end

local function waitForMachineStart(demands)
    print("waiting for machine to start")
    local timeout = 0
    local maxWait = 60

    while gtm.getWorkProgress() <= 0 do
        if not hasDemandFluid(demands) then
            print("machine accepted all plasma; task complete")
            return true
        end
        os.sleep(0.5)
        timeout = timeout + 0.5
        if timeout >= maxWait then
            print("machine start timeout; journal retained, will keep waiting")
            return false
        end
    end

    print("machine started")
    return true
end

local function printFluidInfo()
    for i = 1, #cacheTable do
        local stack = database.get(i)
        print(tostring(stack and stack.label), cacheTable[i])
    end
end

local function runActiveTask()
    local demands = activeTask.demands
    restoreDatabase(demands)
    cacheTable = {}
    for i, demand in ipairs(demands) do cacheTable[i] = demand.remaining end

    if activeTask.phase == "prepared" then
        print("[state] demand journal ready; moving original inputs")
        if not clearCacheBuffer() then return end
        activeTask.phase = "transferring"
        if not saveTask() then error("cannot persist task phase") end
    end

    if activeTask.phase == "transferring" then
        print("[state] transferring plasma (restart-safe)")
        processFluid(demands)
        activeTask.phase = "waiting"
        if not saveTask() then error("cannot persist task phase") end
    end

    if activeTask.phase == "waiting" then
        if waitForMachineStart(demands) then
            activeTask.phase = "cleanup"
            if not saveTask() then error("cannot persist task phase") end
        end
    end

    if activeTask.phase == "cleanup" then
        if clearResidualPlasma() then
            clearTask()
            print("[state] task journal cleared")
        end
    end
end

local function main()
    activeTask = loadTask()
    if activeTask ~= nil then
        print(string.format("[state] recovering interrupted task, phase=%s", tostring(activeTask.phase)))
    end

    while true do
        if activeTask ~= nil then
            runActiveTask()
        else
            cacheCount = 1
            cacheTable = {}
            cacheSourceTable = {}
            demandTable = {}

            local fluid = trans.getFluidInTank(sideCacheBuffer, 1)
            if fluid ~= nil and tankAmount(sideCacheBuffer, 1) <= 64 then
                orphanPlasmaWarned = false
                print("init database")
                setDatabase()

                if validateDatabase() then
                    print("all inputs valid; recording demands before moving inputs")
                    printFluidInfo()
                    activeTask = {
                        version = 1,
                        phase = "prepared",
                        demands = demandTable,
                    }
                    if saveTask() then
                        print("[state] saved all 7 fluid demands before removing inputs")
                        runActiveTask()
                    else
                        activeTask = nil
                        print("[state] input not moved because journal could not be saved")
                    end
                else
                    print("[scan bad] input not moved; fix mapping/input and rerun")
                end
            elseif fluid ~= nil and tostring(fluid.name or ""):match("^plasma%.") and not orphanPlasmaWarned then
                print("[state] orphan plasma found without a journal; this old interrupted batch cannot be reconstructed automatically")
                print("[state] clear the malformed cache once, then new batches will be restart-safe")
                orphanPlasmaWarned = true
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
