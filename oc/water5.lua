local component = require("component")
local computer = require("computer")
local os = require("os")
local sides = require("sides")

local PLASMA = "plasma.helium"
local COOLANT = "supercoolant"
local GRADE4 = "grade4purifiedwater"

-- just change here is enough. 1 more adapter for fluid_interface
local sidePlasma = sides.down
local sideCoolant = sides.west
local sideInterface = sides.east -- Old transposer faces the ME dual interface.

local heatingCycles = 3
local plasmaPerCycle = 100
local coolantPerCycle = 2000
local grade4PerParallel = 1000
local checkAfterTicks = 110 * 20 -- Last 10 seconds of each 120-second recipe.

local function clean(value)
    return tostring(value or ""):gsub("§.", "")
end

local function finalNumber(value)
    return tonumber(clean(value):match("(%d+)%D*$"))
end

local function findMachine()
    local found = {}
    for address in component.list("gt_machine", true) do
        local proxy = component.proxy(address)
        local ok, info = pcall(proxy.getSensorInformation)
        if ok and type(info) == "table" then
            for _, line in ipairs(info) do
                if tostring(line):find("purification_unit_plasma_heater.temperature", 1, true) then
                    found[#found + 1] = {address = address, proxy = proxy}
                    break
                end
            end
        end
    end
    assert(#found == 1, "expected one plasma-heater gt_machine; found " .. #found)
    print("[init] plasma-heater adapter=" .. found[1].address)
    return found[1].proxy
end

local function findInterface()
    local found = {}
    for address in component.list("fluid_interface", true) do
        found[#found + 1] = {address = address, proxy = component.proxy(address)}
    end
    assert(#found == 1, "expected one fluid_interface; found " .. #found)
    print("[init] main-network adapter=" .. found[1].address)
    return found[1].proxy
end

local function findTransposer()
    local found = {}
    for address in component.list("transposer", true) do
        found[#found + 1] = {address = address, proxy = component.proxy(address)}
    end
    assert(#found == 1, "expected one transposer; found " .. #found)
    print("[init] interface-cache transposer=" .. found[1].address .. " side=" .. sideInterface)
    return found[1].proxy
end

local machine = findMachine()
local fluidInterface = findInterface()
local transposer = findTransposer()

local function readSensors(info)
    local temperature, cycle, parallel, success
    for _, raw in ipairs(info) do
        local line = clean(raw)
        local lower = line:lower()
        if lower:find("purification_unit_plasma_heater.temperature", 1, true) then
            temperature = finalNumber(line)
        elseif lower:find("purification_unit_plasma_heater.heating_cycles", 1, true) then
            cycle = finalNumber(line)
        elseif lower:find("parallel", 1, true) or line:find("并行", 1, true) then
            parallel = finalNumber(line)
        end
        if (lower:find("success", 1, true) or line:find("成功", 1, true)) and line:find("%%") then
            success = tonumber(line:match("([%d%.]+)%s*%%"))
        end
    end
    return temperature or finalNumber(info[4]), cycle or finalNumber(info[5]), parallel, success
end

local function readCache()
    local ok, count = pcall(transposer.getTankCount, sideInterface)
    if not ok or type(count) ~= "number" or count < 1 then return nil, "cannot read dual-interface tanks: " .. tostring(count) end
    local amounts = {}
    for tank = 1, count do
        local readOk, fluid = pcall(transposer.getFluidInTank, sideInterface, tank)
        if not readOk then return nil, "cannot read interface tank " .. tank .. ": " .. tostring(fluid) end
        if fluid and fluid.name then
            amounts[fluid.name] = (amounts[fluid.name] or 0) + (tonumber(fluid.amount) or 0)
        end
    end
    return amounts
end

local function readNetworkWater()
    local ok, fluids = pcall(fluidInterface.getFluidsInNetwork)
    if not ok or type(fluids) ~= "table" then return nil, "cannot read main-network fluids: " .. tostring(fluids) end
    local amount = 0
    for _, fluid in ipairs(fluids) do
        if fluid.name == GRADE4 then amount = amount + (tonumber(fluid.amount) or 0) end
    end
    return amount
end

local function checkInputs(parallel)
    local cache, cacheError = readCache()
    local water, networkError = readNetworkWater()
    local plasma = cache and (cache[PLASMA] or 0) or nil
    local coolant = cache and (cache[COOLANT] or 0) or nil
    local plasmaNeed = heatingCycles * plasmaPerCycle
    local coolantNeed = heatingCycles * coolantPerCycle
    local waterNeed = parallel and parallel * grade4PerParallel or nil

    print(string.format("[check] interface plasma=%s/%d L, coolant=%s/%d L",
        tostring(plasma), plasmaNeed, tostring(coolant), coolantNeed))
    print(string.format("[check] network grade4=%s/%s L, machine parallel=%s",
        tostring(water), tostring(waterNeed), tostring(parallel)))

    if cacheError then return false, cacheError end
    if networkError then return false, networkError end
    if not parallel or parallel < 1 then return false, "machine parallel unavailable" end
    if plasma < plasmaNeed then return false, "interface helium plasma below 3 cycles" end
    if coolant < coolantNeed then return false, "interface supercoolant below 3 cycles" end
    if water < waterNeed then return false, "main-network grade 4 water below machine parallel" end
    return true, "all inputs sufficient"
end

local function interfaceSlot(fluidName, amount)
    local ok, count = pcall(transposer.getTankCount, sideInterface)
    if not ok or type(count) ~= "number" then return nil end
    for tank = 1, count do
        local readOk, fluid = pcall(transposer.getFluidInTank, sideInterface, tank)
        if readOk and fluid and fluid.name == fluidName and (tonumber(fluid.amount) or 0) >= amount then
            return tank - 1 -- transferFluid uses zero-based slots.
        end
    end
    return nil
end

local function feedFluid(fluidName, amount, targetSide)
    local slot = interfaceSlot(fluidName, amount)
    if not slot then
        print(string.format("[feed] waiting for interface %s: need %d L", fluidName, amount))
        return false
    end
    local ok, moved, movedAmount = pcall(transposer.transferFluid, sideInterface, targetSide, amount, slot)
    if not ok or not moved then
        print("[feed] transfer failed: " .. fluidName .. " " .. tostring(moved))
        return false
    end
    print(string.format("[feed] %s moved=%s/%d L", fluidName, tostring(movedAmount), amount))
    return true
end

local lastProgress = 0
local lastCycle, lastSuccess = nil, nil
local checkedThisRecipe = false
local stoppedByScript = false
local savedParallel = nil
local lastRetry, lastFeed, nextFeedAt = 0, 0, 0
local initialProbeDone = false

while true do
    local okInfo, info = pcall(machine.getSensorInformation)
    local okProgress, progress = pcall(machine.getWorkProgress)
    if not okInfo or type(info) ~= "table" or not okProgress or type(progress) ~= "number" then
        print("[read] machine sensor unavailable; retrying")
        os.sleep(5)
    else
        local temperature, cycle, parallel, success = readSensors(info)
        if progress > 0 and parallel and parallel > 0 then savedParallel = parallel end
        if progress < lastProgress then checkedThisRecipe = false end

        if not initialProbeDone then
            initialProbeDone = true
            print("[init] first live read from both adapters and the interface cache:")
            local _, reason = checkInputs(parallel)
            print("[init] " .. reason)
        end

        if cycle ~= lastCycle then
            print(string.format("[state] progress=%.1f s cycle=%s temp=%s K parallel=%s",
                progress / 20, tostring(cycle), tostring(temperature), tostring(parallel)))
            lastCycle = cycle
        end
        if success and success ~= lastSuccess then
            print(string.format("[state] success rate=%.1f%%", success))
            lastSuccess = success
        end

        if not stoppedByScript and cycle and cycle >= heatingCycles
            and progress >= checkAfterTicks and not checkedThisRecipe then
            checkedThisRecipe = true
            local enough, reason = checkInputs(parallel)
            print("[decision] " .. reason)
            if not enough then
                local stopOk, result = pcall(machine.setWorkAllowed, false)
                if stopOk and result ~= false then
                    stoppedByScript = true
                    print("[decision] disabled before next 120-second recipe")
                else
                    print("[decision] failed to disable machine: " .. tostring(result))
                end
            end
        end

        if stoppedByScript then
            if computer.uptime() - lastRetry >= 10 then
                lastRetry = computer.uptime()
                local enough, reason = checkInputs(savedParallel)
                print("[retry] " .. reason)
                if enough and progress == 0 then
                    local startOk, result = pcall(machine.setWorkAllowed, true)
                    if startOk and result ~= false then
                        stoppedByScript = false
                        checkedThisRecipe = false
                        print("[retry] inputs restored; machine enabled")
                    else
                        print("[retry] failed to enable machine: " .. tostring(result))
                    end
                end
            end
        elseif progress > 0 and cycle and cycle < heatingCycles and temperature
            and computer.uptime() >= nextFeedAt and computer.uptime() - lastFeed >= 1 then
            lastFeed = computer.uptime()
            if temperature == 0 then
                if transposer.getTankLevel(sidePlasma) == 0 then
                    if feedFluid(PLASMA, plasmaPerCycle, sidePlasma) then
                        nextFeedAt = computer.uptime() + 10
                    end
                end
            elseif transposer.getTankLevel(sideCoolant) == 0 then
                if feedFluid(COOLANT, coolantPerCycle, sideCoolant) then
                    nextFeedAt = computer.uptime() + 20
                end
            end
        end

        lastProgress = progress
        os.sleep(0.5)
    end
end
