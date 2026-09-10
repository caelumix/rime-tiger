-- librime 处理器薄封装
local adapter = require("tiger_sentence.rime.adapter")

local M = {}

---@param env Env
function M.fini(env)
    adapter.deactivate(env)
end

---@param key_event KeyEvent
---@param env Env
---@return integer
function M.func(key_event, env)
    return adapter.processor(key_event, env)
end

return M
