-- 检验空补充词表不会进入逐字符匹配路径
local root = arg[1] or "."

package.path = root .. "/lua/?.lua;" .. package.path
rime_api = {
    get_user_data_dir = function()
        return "/nonexistent"
    end,
    get_shared_data_dir = function()
        return root
    end,
}

local supplement = require("tiger_sentence.decoder.supplement")
rawset(supplement, "advance", function()
    error("空补充词表调用了匹配器")
end)

local decoder = require("tiger_sentence.decoder")
assert(#decoder.decode_full("aaaaaaaa") > 0, "空补充词表阻断了解码")
