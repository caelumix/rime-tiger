-- 各组件的 engine 包装对象不同，通过原生 context 属性关联同一会话
local M = {}
local sessions = setmetatable({}, { __mode = "v" })
local session_property = "tiger_sentence_session"
local next_session = 0

---@class TigerSentenceSessionState
---@field committed_text string
---@field committed_raw string
---@field trackers table<string, table>
---@field last_seen_raw string
---@field last_auto_commit_raw_length integer
---@field empty_code_pending table|nil
---@field dot_armed boolean
---@field suspended boolean

local function empty_state()
    return {
        committed_text = "",
        committed_raw = "",
        trackers = {},
        last_seen_raw = "",
        last_auto_commit_raw_length = 0,
        empty_code_pending = nil,
        dot_armed = false,
        suspended = false,
    }
end

---@param env Env
---@return TigerSentenceSessionState
function M.get(env)
    local context = env.engine.context
    local id = context:get_property(session_property)
    local state = sessions[id]
    if not state then
        next_session = next_session + 1
        id = tostring(next_session)
        state = empty_state()
        sessions[id] = state
        context:set_property(session_property, id)
    end
    -- env 存活期间保留状态；组件释放后由弱值表允许回收
    env.tiger_sentence_state = state
    return state
end

---@param env Env
function M.reset(env)
    local state = M.get(env)
    for key in pairs(state) do
        state[key] = nil
    end
    for key, value in pairs(empty_state()) do
        state[key] = value
    end
end

return M
