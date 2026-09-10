-- 空闲时处理快符、数字和小数点；组合中不拦截选重
local M = {}
local state_store = require("tiger_sentence.rime.state")
local symbols = {
    a = "！",
    b = "》",
    c = "】",
    d = "、",
    e = "（",
    f = "“",
    g = "”",
    h = "『",
    i = "——",
    j = "』",
    k = "￥",
    l = "%",
    m = "」",
    n = "「",
    o = "〖",
    p = "〗",
    q = "：“",
    r = "）",
    s = "……",
    t = "→",
    u = "~",
    v = "《",
    w = "？",
    x = "【",
    y = "·",
    z = "|",
}

local function has_modifier(key_event)
    return key_event:shift()
        or key_event:caps()
        or key_event:ctrl()
        or key_event:alt()
        or key_event:super()
end

local function is_semicolon(representation)
    return representation == ";" or representation == "semicolon"
end

local function is_modifier(representation)
    return representation:match("^Shift")
        or representation:match("^Control")
        or representation:match("^Alt")
        or representation:match("^Super")
        or representation:match("^Meta")
        or representation:match("^Caps_Lock$")
        or representation:match("^Num_Lock$")
        or representation:match("^ISO_Level")
        or representation == "Mode_switch"
end

local function commit(env, value)
    local context = env.engine.context
    context:clear()
    env.engine:commit_text(value)
end

---@param key_event KeyEvent
---@param env Env
---@return integer
function M.func(key_event, env)
    if key_event:release() then
        return 2
    end

    local context = env.engine.context
    local state = state_store.get(env)
    local representation = key_event:repr()
    local dot_armed = state.dot_armed
    if not is_modifier(representation) then
        state.dot_armed = false
    end
    if
        not context:is_composing()
        and not context:get_option("ascii_mode")
        and not key_event:ctrl()
        and not key_event:alt()
        and not key_event:super()
    then
        local digit = representation:match("^([0-9])$") or representation:match("^KP_([0-9])$")
        if digit then
            local output = digit
            if context:get_option("full_shape") then
                output = ({ "０", "１", "２", "３", "４", "５", "６", "７", "８", "９" })[tonumber(
                    digit
                ) + 1]
            end
            env.engine:commit_text(output)
            state.dot_armed = true
            return 1
        end
        if
            dot_armed
            and not key_event:shift()
            and (representation == "period" or representation == "KP_Decimal")
        then
            env.engine:commit_text(".")
            return 1
        end
    end
    if (context.input or "") == ";" then
        if representation == "BackSpace" or representation == "Escape" then
            context:clear()
            return 1
        end
        if has_modifier(key_event) then
            context:clear()
            return 2
        end
        local target = symbols[representation]
        if is_semicolon(representation) then
            target = "；"
        elseif
            representation == "space"
            or representation == "Return"
            or representation == "KP_Enter"
        then
            target = "："
        end
        if target then
            commit(env, target)
            return 1
        end
        context:clear()
        return 2
    end

    if
        context:is_composing()
        or not is_semicolon(representation)
        or context:get_option("ascii_mode")
        or has_modifier(key_event)
    then
        return 2
    end
    return context:push_input(";") and 1 or 2
end

return M
