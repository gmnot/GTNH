local os = require("os")
local component = require("component")
local sides = require("sides")
local term = require("term")
 
local redstone = component.redstone
local transposer = component.transposer
local gtm = component.gt_machine
local UV = "molten.longasssuperconductornameforuvwire"
local UHV = "molten.longasssuperconductornameforuhvwire"
local UEV = "molten.superconductoruevbase"
local UIV = "molten.superconductoruivbase"
local UMV = "molten.superconductorumvbase"
 
-- 请设置输入红石信号的方向和流体输出方向!!
local inputSide = sides.down                      -- 红石信号输入方向
local fluidInputSides = {sides.north, sides.up}   -- 两个流体输入方向
local targetSide = sides.down                     -- 流体输出方向
local superconductor = UHV   -- 超导的等级
 
-- 流体 ID 和输出量配置 (0-7，每个信号对应多个流体 ID 和流量)
local fluidMapping = {
  [0] = {{id = "supercoolant", amount = 10000}},           -- 10000L超级冷却液
  [1] = {{id = "helium", amount = 10000}},                 -- 10000L氦
  [2] = {{id = superconductor, amount = 1440}},            -- 1440L超导
  [3] = {{id = "neon", amount = 7500},                     -- 7500氖+1440超导
         {id = superconductor, amount = 1440}}, 
  [4] = {{id = "molten.neutronium", amount = 4608}},       -- 4608L中子
  [5] = {{id = "krypton", amount = 5000},                  -- 5000L氪+4608L中子
         {id = "molten.neutronium", amount = 4608}}, 
  [6] = {{id = superconductor, amount = 1440},             -- 1440L超导+4608中子
         {id = "molten.neutronium", amount = 4608}}, 
  [7] = {{id = "xenon", amount = 2500},                    -- 2500氙+1440超导+4608L中子
         {id = superconductor, amount = 1440},
         {id = "molten.neutronium", amount = 4608}} 
}
 
-- 寻找流体槽位并检查流体是否足够
local function findFluidSlot(fluidId, requiredAmount)
  for _, fluidSide in ipairs(fluidInputSides) do
    local tankCount = transposer.getTankCount(fluidSide)
    for tank = 1, tankCount do
      local fluidInfo = transposer.getFluidInTank(fluidSide, tank)
      if fluidInfo and fluidInfo.name == fluidId and fluidInfo.amount >= requiredAmount then
        return fluidSide, tank - 1
      end
    end
  end
  return nil, nil
end
 
local function main()
  local lastSignalStrength = -1
  local lastSuccessRate = -1
  local fluidTransferred = {}  -- 记录已经转运成功的流体
 
  while true do
    -- 获取当前红石信号强度
    local signalStrength = redstone.getInput(inputSide)
    
    if signalStrength ~= lastSignalStrength then
      term.clear()
      print("检测红石信号中...")
      print("当前红石信号强度: " .. signalStrength)
      lastSignalStrength = signalStrength  -- 更新上一次的信号值
      fluidTransferred = {}  -- 红石信号改变时清空表格
    end
 
    if signalStrength >= 8 then
      print("位 4 开启 待机中")
      -- 在信号大于 8 时，继续保持状态直到信号变化
      while redstone.getInput(inputSide) >= 8 do
        os.sleep(5)
      end
      term.clear()
    else
      -- 获取成功率
      local info = gtm.getSensorInformation()
      local workProgress = gtm.getWorkProgress()  
 
      if workProgress > 1 and info[2] ~= nil then
        local successRate = tonumber(string.match(info[2], "%d+"))
        
        -- 无论成功率是否变化，都进行检查
        if successRate ~= lastSuccessRate or successRate < 100 then
          print("当前成功率: " .. successRate .. "%")
          lastSuccessRate = successRate
 
          if successRate < 100 then
            -- 如果成功率小于100，则根据红石信号执行流体传输操作
            if fluidMapping[signalStrength] then
              print("信号对应的流体配置:")
              for _, fluidInfo in ipairs(fluidMapping[signalStrength]) do
                local fluidId = fluidInfo.id
                local amount = fluidInfo.amount
 
                -- 如果流体已转运过，则跳过
                if fluidTransferred[fluidId] then
                  print(string.format("流体 %s 已经转运过,跳过", fluidId))
                else
                  local fluidSide, slot = findFluidSlot(fluidId, amount)
 
                  if fluidSide and slot then
                    local success = transposer.transferFluid(fluidSide, targetSide, amount, slot)
                    if success then
                      print(string.format("流体 %s 传输成功 (%d mB)", fluidId, amount))
                      fluidTransferred[fluidId] = true  -- 记录已转运的流体
                    end
                  else
                    print(string.format("流体 %s 不足,请检查库存 (%d mB)", fluidId, amount))
                  end
                end
              end
            end
          else
            -- 如果成功率已达到 100% 持续待机并清空记录表格
            print("成功率已达到 100% 等待下一次变化。")
            fluidTransferred = {}  -- 清空流体转运记录
          end
        end
      end
    end
 
    os.sleep(5)
  end
end
 
main()