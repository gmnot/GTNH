local os = require("os")
local component = require("component")
local sides = require("sides")
 
local gtm = component.gt_machine
local trans = component.transposer
 
local sideInput = sides.west --Me接口的方向
local sideOutput = sides.up --输入总线的方向
 
local index = 1
local inputTable = { 1, 2, 3, 4, 5, 6, 2, 4, 6, 1, 3, 5, 1, 4, 6, 3, 2, 5 }
 
local function main()
 
    while true do
        os.sleep(3)
        if index == 19 then index = 1 end
 
        local info = gtm.getSensorInformation()
        local workProgress = gtm.getWorkProgress()  
        print(string.format("Work progress: %.2f s", workProgress / 20))
        if workProgress > 200 and info[2] ~= nil then
            local successRate = tonumber(string.match(info[2], "%d+"))
            print("Success rate = " .. successRate .. "%")
            if successRate ~= 100 then
                local slot = inputTable[index]
                local transferred = trans.transferItem(sideInput, sideOutput, 1, slot)
                if transferred > 0 then
                    print(string.format("Transferred %d item(s) from slot %d", transferred, slot))
                    index = index + 1
                else
                    print(string.format("Transfer failed from slot %d", slot))
                end
            end
        end
    end
end
 
main()
