-- 检验快符映射及其与既有分号选重的相位隔离
local root = arg[1] or "."
package.path = root .. "/lua/?.lua;" .. package.path

local expected = {
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

local function environment()
    local context = {
        input = "",
        get_property = function(self, name)
            return rawget(self, name) or ""
        end,
        set_property = rawset,
        ascii_mode = false,
        full_shape = false,
        clear = function(self)
            self.input = ""
        end,
        get_option = function(self, name)
            return (name == "ascii_mode" and self.ascii_mode)
                or (name == "full_shape" and self.full_shape)
                or false
        end,
        is_composing = function(self)
            return self.input ~= ""
        end,
        push_input = function(self, value)
            self.input = self.input .. value
            return true
        end,
    }
    return {
        engine = {
            context = context,
            commit_text = function(_, value)
                context.committed = (context.committed or "") .. value
            end,
        },
    }
end

local function key(representation, options)
    options = options or {}
    return {
        alt = function()
            return options.alt or false
        end,
        caps = function()
            return options.caps or false
        end,
        ctrl = function()
            return options.ctrl or false
        end,
        release = function()
            return options.release or false
        end,
        repr = function()
            return representation
        end,
        shift = function()
            return options.shift or false
        end,
        super = function()
            return options.super or false
        end,
    }
end

local quick_symbol = require("tiger_sentence.rime.quick_symbol")
for letter, symbol in pairs(expected) do
    local env = environment()
    assert(quick_symbol.func(key("semicolon"), env) == 1)
    assert(env.engine.context.input == ";")
    assert(quick_symbol.func(key(letter), env) == 1)
    assert(env.engine.context.input == "" and env.engine.context.committed == symbol)
end

local punctuation_env = environment()
assert(quick_symbol.func(key(";"), punctuation_env) == 1)
assert(quick_symbol.func(key("semicolon"), punctuation_env) == 1)
assert(punctuation_env.engine.context.committed == "；")

for _, representation in ipairs({ "space", "Return" }) do
    local env = environment()
    assert(quick_symbol.func(key("semicolon"), env) == 1)
    assert(quick_symbol.func(key(representation), env) == 1)
    assert(env.engine.context.committed == "：")
end

local invalid_env = environment()
assert(quick_symbol.func(key("semicolon"), invalid_env) == 1)
assert(quick_symbol.func(key("1"), invalid_env) == 2)
assert(invalid_env.engine.context.input == "" and invalid_env.engine.context.committed == nil)

local cancelled_env = environment()
assert(quick_symbol.func(key("semicolon"), cancelled_env) == 1)
assert(quick_symbol.func(key("BackSpace"), cancelled_env) == 1)
assert(cancelled_env.engine.context.input == "" and cancelled_env.engine.context.committed == nil)

for _, options in ipairs({
    { alt = true },
    { caps = true },
    { ctrl = true },
    { shift = true },
    { super = true },
    { release = true },
}) do
    local env = environment()
    assert(quick_symbol.func(key("semicolon", options), env) == 2)
    assert(env.engine.context.input == "" and env.engine.context.committed == nil)
end

local ascii_env = environment()
ascii_env.engine.context.ascii_mode = true
assert(quick_symbol.func(key("semicolon"), ascii_env) == 2)
assert(ascii_env.engine.context.input == "" and ascii_env.engine.context.committed == nil)

local number_env = environment()
assert(quick_symbol.func(key("KP_3"), number_env) == 1)
assert(number_env.engine.context.committed == "3")
assert(quick_symbol.func(key("Shift_L"), number_env) == 2)
assert(quick_symbol.func(key("period"), number_env) == 1)
assert(number_env.engine.context.committed == "3.")
assert(quick_symbol.func(key("period"), number_env) == 2, "小数点状态没有单次消费")

local full_number_env = environment()
full_number_env.engine.context.full_shape = true
assert(quick_symbol.func(key("8"), full_number_env) == 1)
assert(quick_symbol.func(key("KP_Decimal"), full_number_env) == 1)
assert(full_number_env.engine.context.committed == "８.")

local caps_number_env = environment()
assert(quick_symbol.func(key("1", { caps = true }), caps_number_env) == 1)
assert(quick_symbol.func(key("period", { caps = true }), caps_number_env) == 1)
assert(caps_number_env.engine.context.committed == "1.")

local cleared_number_env = environment()
assert(quick_symbol.func(key("1"), cleared_number_env) == 1)
assert(quick_symbol.func(key("a"), cleared_number_env) == 2)
assert(quick_symbol.func(key("period"), cleared_number_env) == 2)
