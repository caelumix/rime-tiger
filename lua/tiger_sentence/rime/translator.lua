-- librime 翻译器薄封装
local adapter = require("tiger_sentence.rime.adapter")

local M = {}

---@param input string
---@param segment Segment
---@param env Env
function M.func(input, segment, env)
    adapter.translator(input, segment, env)
end

return M
