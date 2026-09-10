-- 检验补充语料解析与奖励匹配
local root = arg[1] or "."
package.path = root .. "/lua/?.lua;" .. package.path

rime_api = {
    get_user_data_dir = function()
        return "/nonexistent"
    end,
}

local supplement = require("tiger_sentence.decoder.supplement")
assert(supplement.load(root .. "/tiger_sentence.supplement.example.txt").count == 17)
rawset(rime_api, "get_user_data_dir", function()
    return root
end)
assert(supplement.load_default().count == 0, "缺失私有补充文件不应回退到示例")
assert(supplement.reward_for_weight(1000) == 9, "默认补充奖励错误")
assert(supplement.reward_for_weight(1) == 0, "补充奖励下限错误")
assert(supplement.reward_for_weight(1000000000) == 16, "补充奖励上限错误")

local matcher = supplement.build({ ["人工智能"] = 1000, ["智能"] = 3000 })
local state = 1
for _, character in ipairs({ "人", "工", "智" }) do
    local reward
    state, reward = supplement.advance(matcher, state, character)
    assert(reward == 0, "未完成补充词提前获得奖励")
end
local reward
state, reward = supplement.advance(matcher, state, "能")
assert(reward == supplement.reward_for_weight(3000), "重叠补充词没有采用最高奖励")

local temporary = os.tmpname()
local missing = supplement.load(temporary .. ".missing")
assert(missing.count == 0 and missing.error, "缺失补充文件没有安全降级")
local ok, error_message = xpcall(function()
    local file = assert(io.open(temporary, "wb"))
    assert(
        file:write(
            "\239\187\191# 注释\r\n甲测词\n甲测词 5000\n无效 0\n错误 abc\n\255 1000\r乙测词 3000\n"
        )
    )
    assert(file:close())
    local loaded = supplement.load(temporary)
    assert(loaded.count == 2, "补充语料没有过滤无效项或合并重复项")
    local current = 1
    current = supplement.advance(loaded, current, "甲")
    current = supplement.advance(loaded, current, "测")
    local matched
    current, matched = supplement.advance(loaded, current, "词")
    assert(matched == supplement.reward_for_weight(5000), "重复词条没有采用最后权重")
end, debug.traceback)
os.remove(temporary)
assert(ok, error_message)

-- 通过真实文件句柄注入失败，错误状态必须保留
local open = io.open
for _, operation in ipairs({ "read", "close" }) do
    rawset(io, "open", function(path, mode)
        local handle, message = open(path, mode)
        if not handle then
            return nil, message
        end
        return setmetatable({}, {
            __index = function(_, name)
                return function(_, ...)
                    if name == operation then
                        if operation == "close" then
                            handle:close()
                        end
                        return nil, "注入的补充文件故障"
                    end
                    return handle[name](handle, ...)
                end
            end,
        })
    end)
    local loaded = supplement.load(root .. "/tiger_sentence.supplement.example.txt")
    io.open = open
    assert(loaded.count == 0 and loaded.error == "注入的补充文件故障")
end

local api = rime_api
rime_api = nil
assert(supplement.load_default().count == 0)
rime_api = api
rawset(rime_api, "get_user_data_dir", function()
    return ""
end)
assert(supplement.load_default().count == 0)
rawset(rime_api, "get_user_data_dir", function()
    error("注入的目录查询故障")
end)
local queried, query_error = pcall(supplement.load_default)
assert(not queried and tostring(query_error):find("注入的目录查询故障", 1, true))
