-- 静态符号表及 Lua 旁路检查；原生逐键行为见 rime_symbols.cc
local root = arg[1] or "."

local function read_all(path)
    local file = assert(io.open(path, "r"), "无法打开：" .. path)
    local value = assert(file:read("*a"))
    assert(file:close())
    return value
end

local source = read_all(root .. "/dicts/tiger_sentence_symbols.yaml")
local full_shape = assert(source:match("  full_shape:\n(.-)  half_shape:\n"))
local half_shape = assert(source:match("  half_shape:\n(.-)\nsymbols:\n"))
assert(full_shape:find('    " ": { commit: "　" }', 1, true))
-- `/` 必须保留为候选列表；commit 会在首键立即上屏，无法继续输入分类编码
assert(full_shape:find('    "/": [／]', 1, true))
assert(half_shape:find('    "/": ["/"]', 1, true))
assert(not full_shape:find('    "/": { commit:', 1, true))
assert(not half_shape:find('    "/": { commit:', 1, true))
assert(half_shape:find([[    "'": { pair: [ "‘", "’" ] }]], 1, true))
local symbols = {}
for line in source:gmatch("[^\r\n]+") do
    local code, body = line:match("^  '(/[a-z]+)': %[(.*)%]$")
    if code then
        assert(not symbols[code], "符号编码重复：" .. code)
        local values = {}
        for raw_value in body:gmatch("[^,]+") do
            local value = raw_value:match("^%s*(.-)%s*$")
            assert(value ~= "", "符号候选为空：" .. code)
            values[#values + 1] = value
        end
        symbols[code] = values
    end
end

local expected_counts = {
    ["/bd"] = 33,
    ["/chu"] = 1,
    ["/cuo"] = 8,
    ["/dui"] = 7,
    ["/dw"] = 14,
    ["/ewd"] = 33,
    ["/ewx"] = 33,
    ["/hb"] = 7,
    ["/jg"] = 12,
    ["/jm"] = 87,
    ["/jt"] = 10,
    ["/lmd"] = 12,
    ["/lmx"] = 12,
    ["/pai"] = 2,
    ["/pi"] = 2,
    ["/pjm"] = 89,
    ["/py"] = 26,
    ["/sb"] = 17,
    ["/sm"] = 1,
    ["/sx"] = 45,
    ["/szd"] = 20,
    ["/szh"] = 10,
    ["/szk"] = 20,
    ["/szq"] = 10,
    ["/tm"] = 1,
    ["/ts"] = 27,
    ["/xb"] = 17,
    ["/xld"] = 24,
    ["/xlx"] = 24,
    ["/zb"] = 22,
    ["/zy"] = 37,
}

for code, count in pairs(expected_counts) do
    assert(symbols[code], "缺少符号编码：" .. code)
    assert(#symbols[code] == count, "符号候选数量错误：" .. code)
end
for code in pairs(symbols) do
    assert(expected_counts[code], "存在未登记的符号编码：" .. code)
end

assert(#symbols["/szq"] == 10 and symbols["/szq"][10] == "⑩")
assert(#symbols["/szk"] == 20 and symbols["/szk"][20] == "⒇")
assert(symbols["/bd"][1] == "“”" and symbols["/bd"][2] == "（）")
assert(symbols["/jm"][14] == "ぎ" and symbols["/jm"][15] == "ぱ")
assert(table.concat(symbols["/pi"]) == table.concat(symbols["/pai"]))
assert(table.concat(symbols["/dui"]) == "✅☑✓✔⭕√🙆")
assert(table.concat(symbols["/cuo"]) == "❌✖✗✘×☒❎🙅")

local schema = read_all(root .. "/tiger_sentence.schema.yaml")
assert(schema:match("%- ascii_segmentor%s+%- matcher%s+%- abc_segmentor"))
assert(schema:match("__include: dicts/tiger_sentence_symbols:/symbols"))
assert(schema:match("__include: default:/recognizer/patterns"))
assert(schema:match("punct: '%^/%[a%-z%]%+%$'"))

package.path = root .. "/lua/?.lua;" .. package.path
rime_api = {
    get_user_data_dir = function()
        return "/nonexistent"
    end,
    get_shared_data_dir = function()
        return "/nonexistent"
    end,
}
local adapter = require("tiger_sentence.rime.adapter")
local decoder = require("tiger_sentence.decoder")
rawset(decoder, "decode", function()
    error("分类符号不应进入整句解码器")
end)
rawset(decoder, "decode_full", decoder.decode)
local env = {
    engine = {
        context = {
            input = "",
            get_option = function()
                return true
            end,
            is_composing = function()
                return true
            end,
        },
    },
}
local key = {
    repr = function()
        return "a"
    end,
    release = function()
        return false
    end,
    ctrl = function()
        return false
    end,
    alt = function()
        return false
    end,
    super = function()
        return false
    end,
}
for _, input in ipairs({ "/", "/s", "/sz", "/szq", "/unknown", "[", "]", "\\" }) do
    env.engine.context.input = input
    assert(adapter.processor(key, env) == 2, "分类符号按键没有交回 Rime")
    adapter.translator(input, {}, env)
    assert(env.engine.context.input == input, "整句入口改写了分类符号输入")
end
