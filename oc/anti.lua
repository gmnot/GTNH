local component = require("component")
local os = require("os")
local sides = require("sides")
 
local tr = component.transposer
--以下是需要根据自己实际情况需要更改的量
local antired = component.proxy("518913ad-f51f-41ed-a9b3-374452400895")  --控制反物质仓的红石IO端口对应的uuid
local aered = component.proxy("5fa40a0a-beaf-4f32-978b-49168d7847aa")  --控制量子缸的红石IO端口对应的uuid
local mred = component.proxy("9f84cf7a-dc7a-4dca-a55a-957d88e06af1")  --控制机器开关的红石IO端口对应的uuid
local synred = component.proxy("a1775a12-e465-4f57-90d2-91a72162acdd") --接收主机合成进度信号的红石IO端口对应的uuid
local trig = component.proxy("94ab179f-7814-4245-a7cb-c0aadaa6df50") --接收拉杆信号的红石IO端口对应的uuid
 
local sidered = sides.up --3个控制用红石IO端口发出信号的方向
local sideae = sides.up --量子缸在转运器的哪个方向
local sidetp = sides.down --流体缓存器在转运器的哪个方向
local synside = sides.east --主机合成信号在红石IO端口的哪个方向
local trigside = sides.up --拉杆在红石IO端口的哪个方向
 
local threshold = 2000000 --反物质的阈值，超过此数的转移至产物ae

local sideNames = {
    [sides.down] = "down",
    [sides.up] = "up",
    [sides.north] = "north",
    [sides.south] = "south",
    [sides.west] = "west",
    [sides.east] = "east",
}

local function sideName(side)
    return (sideNames[side] or "unknown") .. "(" .. tostring(side) .. ")"
end

function reset() --执行重新排序操作
    antired.setOutput(sidered, 15)  --对反物质仓输出一次红石信号，控制校准器清空反物质仓
    antired.setOutput(sidered, 0)
    sum = tr.getTankLevel(sideae) --读取此时量子缸里的流体数量，记为总和
    md = sum % 16 --计算平分后的数量
    local count = md
    if sum > threshold then --记录大于阈值的数量
        count = sum - threshold
    end
    print("[reset] level=" .. tostring(sum) .. ", transfer=" .. tostring(count))
    tr.transferFluid(sideae, sidetp, count) --将超出阈值的数量转移到产物ae
    aered.setOutput(sidered, 15)  --发出一次信号控制量子缸进行流体平分
    aered.setOutput(sidered, 0)
end
 
local function main()
    -- os.execute("cls")

    local fl = 1 --定义拉杆信号
    local f666 = 0 --定义主机合成进度信号
    
    mred.setOutput(sidered, 0) --关机 
    reset() --执行一次排序操作
    mred.setOutput(sidered, 15) --开机 
    
    while fl > 0 do
        os.sleep(0) --中断一下,同时避免长时间运行会导致too long without yielding
        f666 = synred.getInput(synside) --获取主机合成进度信号
        if f666 > 0 and f666 < 10 then --主机在合成中，重新平分变化后的流体
            print("[loop] syn=" .. tostring(f666) .. ", reset")
            reset()
        end
        fl = trig.getInput(trigside) --获取拉杆信号，检查是否要停机
    end
    print("[stop] trig=" .. tostring(fl) .. ", machine off")
    mred.setOutput(sidered, 0) --循环结束，关闭机器
 
end
 
main()
