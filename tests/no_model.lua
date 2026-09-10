-- 检验无模型解码语义及错误诊断
local root = arg[1] or "."
package.path = root .. "/lua/?.lua;" .. package.path

local errors = {}
log = {
    error = function(message)
        errors[#errors + 1] = message
    end,
}
rime_api = {
    get_user_data_dir = function()
        return "/nonexistent"
    end,
    get_shared_data_dir = function()
        return "/nonexistent"
    end,
}

local model = require("tiger_sentence.model")
local status = model.status()
assert(not status.loaded and status.error, "模型缺失没有保留错误状态")
assert(#errors == 1 and errors[1]:find(status.error, 1, true), "模型错误没有记录一次")
assert(model.logp(model.BOS, model.BOS, "你") == 0, "无模型概率不是零")
assert(model.isolation_penalty("龘") == 0, "无模型仍计算生僻字惩罚")
assert(#errors == 1, "模型错误被重复记录")

local result = require("tiger_sentence.decoder").decode_full("ldac")
assert(result[1] and result[1].text == "燕", "无模型没有按码表名次输出整句候选")

model.close()
log.error = function()
    error("注入的日志故障")
end
local logged, log_error = pcall(model.status)
assert(not logged and tostring(log_error):find("注入的日志故障", 1, true))
assert(not model.status().loaded and model.status().error, "日志失败丢失模型错误状态")
