local os = require("os")
local component = require("component")
local sides = require("sides")

local trans = component.transposer
local sideCacheBuffer = sides.down       -- Transposer side connected to the large input cache
local sideAEInfusion = sides.north       -- Transposer side connected to the AE Matter Infuser
local sideInterface = sides.east         -- Transposer side connected to the main network's sole AE interface, used for fluid output
local database = component.database
local mei = component.me_interface
local gtm = component.gt_machine
 
local fcFluidDrop = "ae2fc:fluid_drop"
local GTMaterial = {
    [2129] = "Neutronium", [0] = "Draconium", [2976] = "DraconiumAwakened",        -- Handle GT materials whose corresponding plasma cells cannot be found
    [2978] = "Ichorium", [2982] = "CosmicNeutronium", [2984] = "Flerovium_GT5U",      -- Generated cells lack matching fluid names, so explicitly map all relevant GT materials
    [2397] = "Infinity", [2329] = "Tritanium", [2395] = "Bedrockium"}           -- Neutronium, Draconium, Awakened Draconium, Ichorium, Cosmic Neutronium, Flerovium, Infinity, Tritanium, and Bedrockium

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
 
function clearCacheBuffer()     -- Magnetic Matter always outputs one dust and two fluids, so this cleanup logic is fixed
    trans.transferItem(sideCacheBuffer, sideAEInfusion, _, 1)
end
 
function requestItem(item)
    local shouldReportMissingPattern = true
    local cacheN = 0        -- Count failed crafting requests and use the count as the cancellation threshold
    while true do
        local craftable = mei.getCraftables({name=item.name, label=item.label})[1]

        if trans.getFluidInTank(sideInterface, 1).amount >= 8000 then return end     -- Avoid an infinite loop caused by AE latency

        if not craftable then   -- Wait for the player to check the crafting pattern
            if shouldReportMissingPattern then
                shouldReportMissingPattern = false
                print("No matching fluid drop is craftable for " .. item.label .. "; please check the pattern. Waiting...")
            end
            os.sleep(5)
        else
            local result = craftable.request(1, true)      -- Submit the crafting request
            shouldReportMissingPattern = true
            print("Crafting request submitted for", item.label)
            os.sleep(2)

            if result.hasFailed() or result.isCanceled() then
                print("Crafting request failed; retrying in 5 seconds")
                cacheN = cacheN + 1
                if cacheN >= 12 then
                    os.sleep(20)
                    if cacheN > 15 then
                        print("A critical error occurred; manual intervention is required...")
                        while true do os.sleep(5) end
                    end
                    local cpus = mei.getCpus()
                    for i=1,#cpus do     -- Too many failures may indicate an AE issue; try canceling the request first
                        local out = cpus[i].cpu.finalOutput()
                        if out == nil then break end
                        if out.name == item.name and out.label == item.label then
                            cpus[i].cpu.cancel()
                        end
                    end
                end
                os.sleep(5)
            else
                while not result.isDone() do
                    os.sleep(2)
                end
                return
            end
        end
    end
end

function waitForInterfaceFluid(cycle)
    while tankAmount(sideInterface, 1) == 0 do
        requestItem(database.get(1))
        if tankAmount(sideInterface, 1) == 0 then
            print("[cycle " .. tostring(cycle) .. "] fluid still empty after request, retry")
        end
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

            waitForInterfaceFluid(cycle)

            while fluidAmount > 0 do
                local available = tankAmount(sideInterface, 1)
                if available == 0 then
                    print("[cycle " .. tostring(cycle) .. "] interface empty, retry request")
                    waitForInterfaceFluid(cycle)
                else
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
