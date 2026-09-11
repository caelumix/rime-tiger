-- 检验模型格式、生成数据、方案配置与 Rime 按键边界
local root = arg[1] or "."
package.path = root .. "/lua/?.lua;" .. package.path
rime_api = {
    get_user_data_dir = function()
        return root
    end,
    get_shared_data_dir = function()
        return root
    end,
}

local config = require("tiger_sentence.config")
local reader = require("tiger_sentence.model.kn")
local temporary = os.tmpname()

local function write_all(path, value)
    local file = assert(io.open(path, "wb"))
    assert(file:write(value))
    assert(file:close())
end

local function read_all(path)
    local file = assert(io.open(path, "rb"), "无法打开：" .. path)
    local value = assert(file:read("*a"))
    assert(file:close())
    return value
end

local function write(value)
    write_all(temporary, value)
end

local function rejects(value, expected)
    write(value)
    local ok, message = pcall(reader.load, temporary)
    assert(not ok, "损坏模型被意外加载")
    assert(tostring(message):match(expected), tostring(message))
end

local ok, error_message = xpcall(function()
    rejects("UNKNOWN!legacy", "TCSKNM02")
    rejects("TCSKNM02short", "截断")

    local malformed = "TCSKNM02"
        .. string.pack(
            "<I4I4I8I4I4I4I4I8I4I4I8I8I8I4I4I8I8",
            1,
            104,
            104,
            64,
            0,
            1,
            0,
            104,
            1,
            1,
            104,
            104,
            1,
            1,
            0,
            104,
            104
        )
    rejects(malformed, "布局")

    local function structured_mobile(unigram_data, bigram_page)
        bigram_page = bigram_page or string.pack("<I8fI4I4f", 2, 0.5, 1, 1, 0.5)
        local bigram_index_offset = 120 + #bigram_page
        local trigram_offset = bigram_index_offset + 16
        local trigram_index_offset = trigram_offset + 24
        local header = "TCSKNM02"
            .. string.pack(
                "<I4I4I8I4I4I4I4I8I4I4I8I8I8I4I4I8I8",
                1,
                104,
                trigram_index_offset + 16,
                16,
                0,
                2,
                0,
                104,
                1,
                1,
                120,
                bigram_index_offset,
                1,
                1,
                0,
                trigram_offset,
                trigram_index_offset
            )
        local bigram_index = string.pack("<I8I8", 2, 120)
        local trigram_page = string.pack("<I8fI4I4f", 2, 0.5, 1, 1, 0.5)
        local trigram_index = string.pack("<I8I8", 2, trigram_offset)
        return header
            .. unigram_data
            .. bigram_page
            .. bigram_index
            .. trigram_page
            .. trigram_index
    end

    rejects(structured_mobile(string.pack("<i4fi4f", 1, 0.5, 2, 0.5)), "未知一元组键")
    rejects(structured_mobile(string.pack("<i4fi4f", 0, 0.5, -1, 0.5)), "一元组键")
    rejects(structured_mobile(string.pack("<i4fi4f", 0, 0.5, 2, -0.5)), "概率")
    rejects(structured_mobile(string.pack("<i4fi4f", 0, 0.5, 2, 2.0)), "概率")

    local valid = structured_mobile(string.pack("<i4fi4f", 0, 0.5, 2, 0.5))
    write(valid:sub(1, 140) .. string.pack("<f", -0.5) .. valid:sub(145))
    local damaged = reader.load(temporary)
    local queried, query_error = pcall(damaged.logp, reader.BOS, reader.BOS, "\1")
    damaged.close()
    assert(not queried and tostring(query_error):match("后继项概率无效"))

    local successors = {}
    for index = 1, 262145 do
        successors[index] = string.pack("<I4f", index, index == 1 and 0.5 or 0)
    end
    local large_page = string.pack("<I8fI4", 2, 0.5, #successors) .. table.concat(successors)
    write(structured_mobile(string.pack("<i4fi4f", 0, 0.5, 2, 0.5), large_page))
    local large = reader.load(temporary)
    for _ = 1, 2 do
        assert(
            math.abs(large.logp(reader.BOS, reader.BOS, "\1") - math.log(0.75)) < 1e-12,
            "超过常驻缓存预算的合法页不可查询"
        )
    end
    large.close()

    local model = require("tiger_sentence.model")
    local decoder = require("tiger_sentence.decoder")
    local original_load = reader.try_load
    local swapped, swap_error = xpcall(function()
        write(valid)
        model.close()
        local failing = reader.load(temporary)
        local close = failing.close
        failing.close = function()
            error("注入的模型关闭错误")
        end
        rawset(reader, "try_load", function()
            return failing
        end)
        assert(model.available())
        local closed, close_error = pcall(model.close)
        assert(not closed and tostring(close_error):match("注入的模型关闭错误"))
        failing.close = close
        model.close()
        rawset(reader, "try_load", function()
            return reader.load(temporary)
        end)
        local first = decoder.decode("gyy")
        model.close()
        write(structured_mobile(string.pack("<i4fi4f", 0, 0.25, 2, 0.5)))
        local second = decoder.decode("gyy")
        assert(
            first ~= second and first[1].score ~= second[1].score,
            "换模后复用了旧概率或格网"
        )
        model.close()
    end, debug.traceback)
    rawset(reader, "try_load", original_load)
    assert(swapped, swap_error)
end, debug.traceback)
assert(os.remove(temporary))
assert(ok, error_message)

local opened = reader.load(root .. "/models/sentence-ngram-mobile.bin")
local probability_cases = {
    { reader.BOS, reader.BOS, "你", -4.5779349556965103 },
    { reader.BOS, "你", "好", -4.3247722920592437 },
    { "你", "好", reader.EOS, -0.49174358013222436 },
    { "我", "们", "的", -2.343558058579446 },
    { "汩", "罗", "江", -0.7333033067241531 },
    { "龘", "靐", "齉", -13.579114943287355 },
}
for index = 1, #probability_cases do
    local case = probability_cases[index]
    local actual = opened.logp(case[1], case[2], case[3])
    assert(math.abs(actual - case[4]) < 1e-12, "KN 概率偏离本地基准：" .. index)
end
assert(opened.has_observed_bigram("你", "好"), "已知二元组未命中")
assert(not opened.has_observed_bigram("龘", "靐"), "未知二元组被误判为已知")
opened.close()
opened.close()

local original_arguments = arg
local lexicon_output = temporary .. ".lexicon"
local ranks_source = temporary .. ".ranks-source"
local ranks_output = temporary .. ".ranks-output"
local original_open = io.open
local parsed, parse_error = xpcall(function()
    write_all(lexicon_output, "旧词典")
    write_all(ranks_output, "旧字频")
    for _, case in ipairs({
        { "字\ta1e2", "字", "码表条目格式错误" },
        { "\255\taa", "字", "码表条目格式错误" },
        { "字\taa", "\255", "字频条目必须是单个字符" },
    }) do
        write('# version: "20260101"\n' .. case[1] .. "\n")
        write_all(ranks_source, case[2] .. "\n")
        arg = { temporary, ranks_source, lexicon_output, ranks_output }
        local built, build_error = pcall(dofile, root .. "/tools/build_data.lua")
        assert(not built and tostring(build_error):match(case[3]), tostring(build_error))
        assert(read_all(lexicon_output) == "旧词典" and read_all(ranks_output) == "旧字频")
    end
    write_all(ranks_source, "字\n")
    local first
    for _, source_text in ipairs({
        '# version: "20260101"\n字\taa\n',
        '\239\187\191# version: "20260101"\r\n  字 AA  \r\n',
    }) do
        write(source_text)
        dofile(root .. "/tools/build_data.lua")
        local generated = read_all(lexicon_output)
        assert(not first or generated == first, "码表排版改变了生成数据")
        first = generated
    end
    write('# version: "20260101"\n字\taa\n字\taaaa\n')
    dofile(root .. "/tools/build_data.lua")
end, debug.traceback)
io.open = original_open
arg = original_arguments
os.remove(lexicon_output)
os.remove(ranks_source)
os.remove(ranks_output)
assert(os.remove(temporary))
assert(parsed, parse_error)

local transaction_source = temporary .. ".codes"
local transaction_ranks_source = temporary .. ".ranks-source"
local transaction_lexicon = temporary .. ".lexicon"
local transaction_ranks_output = temporary .. ".ranks-output"
write_all(transaction_source, '# version: "20260101"\n字\taa\n')
write_all(transaction_ranks_source, "字\n")
write_all(transaction_lexicon, "旧二进制词典\n")
write_all(transaction_ranks_output, "旧字频模块\n")
local original_rename = os.rename
rawset(os, "rename", function(from, to)
    if from == transaction_ranks_output .. ".tmp" and to == transaction_ranks_output then
        return nil, "注入的字频模块替换故障"
    end
    return original_rename(from, to)
end)
original_arguments = arg
arg = {
    transaction_source,
    transaction_ranks_source,
    transaction_lexicon,
    transaction_ranks_output,
}
local transaction_ok, transaction_error = pcall(dofile, root .. "/tools/build_data.lua")
arg = original_arguments
rawset(os, "rename", original_rename)
local lexicon_read, restored_lexicon = pcall(read_all, transaction_lexicon)
local ranks_read, restored_ranks = pcall(read_all, transaction_ranks_output)
for _, path in ipairs({
    transaction_source,
    transaction_ranks_source,
    transaction_lexicon,
    transaction_ranks_output,
    transaction_lexicon .. ".tmp",
    transaction_ranks_output .. ".tmp",
    transaction_lexicon .. ".bak",
    transaction_ranks_output .. ".bak",
}) do
    os.remove(path)
end
assert(
    not transaction_ok and tostring(transaction_error):match("注入的字频模块替换故障")
)
assert(lexicon_read, restored_lexicon)
assert(ranks_read, restored_ranks)
assert(restored_lexicon == "旧二进制词典\n", "生成失败后没有恢复二进制词典")
assert(restored_ranks == "旧字频模块\n", "生成失败后没有恢复字频模块")

local schema = read_all(root .. "/tiger_sentence.schema.yaml")
-- 方案是用户面，config.lua 是兜底；两者的同名默认值必须一致，改动时不能各自漂移
assert(
    schema:find("  min_retained_raw_length: " .. config.min_retained_raw_length .. "\n", 1, true),
    "方案的最少保留编码默认值与 config.lua 不一致"
)
assert(
    schema:find("  high_freq_limit: " .. config.high_frequency_limit .. "\n", 1, true),
    "方案的高频过滤默认值与 config.lua 不一致"
)
assert(
    schema:find("recognizer:\n  import_preset: default\n", 1, true),
    "recognizer 未导入 Rime 默认规则"
)
local ascii_composer_order = schema:find("    - ascii_composer\n", 1, true)
local recognizer_order = schema:find("    - recognizer\n", 1, true)
local quick_symbol_order = schema:find("lua_processor@*tiger_sentence/rime/quick_symbol", 1, true)
local processor_order = schema:find("lua_processor@*tiger_sentence/rime/processor", 1, true)
local binder_order = schema:find("    - key_binder\n", 1, true)
assert(
    quick_symbol_order
        and ascii_composer_order
        and recognizer_order
        and processor_order
        and binder_order
        and ascii_composer_order < recognizer_order
        and recognizer_order < quick_symbol_order
        and quick_symbol_order < processor_order
        and processor_order < binder_order,
    "Lua 处理器顺序错误"
)
assert(schema:find("accept: semicolon, send: 2", 1, true), "缺少分号次选绑定")
assert(schema:find("accept: apostrophe, send: 3", 1, true), "缺少引号三选绑定")
assert(
    schema:find("accept: Shift+ISO_Left_Tab, send: Up", 1, true)
        and schema:find("accept: ISO_Left_Tab, send: Up", 1, true)
        and schema:find("accept: Shift+Tab, send: Up", 1, true),
    "缺少 Shift+Tab 兼容绑定"
)
local expected_codes = {}
local source = assert(io.open(root .. "/dicts/tiger_sentence.codes.txt", "r"))
local source_version
for line in source:lines() do
    source_version = source_version or line:match('^# version: "(%d%d%d%d%d%d%d%d)"$')
    local value, code = line:match("^([^\t]+)\t([a-z]+)$")
    if value then
        if not expected_codes[code] then
            expected_codes[code] = {}
        end
        expected_codes[code][#expected_codes[code] + 1] = {
            t = value,
            r = #expected_codes[code] + 1,
        }
    end
end
assert(source:close())
assert(source_version, "码表缺少 YYYYMMDD 版本号")

local lexicon = require("tiger_sentence.data.lexicon")
local code_count = 0
local candidate_count = 0
for code, expected in pairs(expected_codes) do
    code_count = code_count + 1
    local generated = assert(lexicon.lookup(code, 0), "二进制词典缺少编码：" .. code)
    assert(#generated == #expected, "候选数量不一致：" .. code)
    for index = 1, #expected do
        candidate_count = candidate_count + 1
        assert(generated[index].t == expected[index].t, "Lua 候选文本不一致：" .. code)
        assert(generated[index].r == expected[index].r, "Lua 候选位置不一致：" .. code)
    end
end
for code in lexicon.entries(0) do
    assert(expected_codes[code], "二进制词典含有源词典之外的编码：" .. code)
end
assert(code_count == 14374, "码表编码总数偏离已审计基线")
assert(candidate_count == 15369, "码表候选总数偏离已审计基线")
assert(lexicon.code_count == code_count, "二进制词典编码总数不一致")
assert(lexicon.candidate_count == candidate_count, "二进制词典候选总数不一致")
assert(lexicon.lookup("u", 0)[1].o, "最优整码单字没有标记")
assert(not lexicon.lookup("ue", 0)[1].o, "非最优整码单字被错误标记")
local filtered_codes, filtered_candidates = 0, 0
for _, candidates in lexicon.entries(config.high_frequency_limit) do
    filtered_codes = filtered_codes + 1
    filtered_candidates = filtered_candidates + #candidates
end
-- 审计基线：默认过滤值或码表变化后必须重新核对这两个数字并同步文档记录
assert(filtered_codes == 13556, "高频过滤后的编码总数偏离已审计基线")
assert(filtered_candidates == 14411, "高频过滤后的候选总数偏离已审计基线")
local maximum_codes, maximum_candidates = 0, 0
local ranks = require("tiger_sentence.data.ranks")
for _, candidates in lexicon.entries(ranks.count) do
    maximum_codes = maximum_codes + 1
    maximum_candidates = maximum_candidates + #candidates
end
local overflow_codes, overflow_candidates = 0, 0
for _, candidates in lexicon.entries(ranks.count + 1) do
    overflow_codes = overflow_codes + 1
    overflow_candidates = overflow_candidates + #candidates
end
assert(
    overflow_codes == maximum_codes and overflow_candidates == maximum_candidates,
    "超出字频表的限制值改变了过滤结果"
)
local default_codes, default_candidates = 0, 0
for _, candidates in lexicon.entries() do
    default_codes = default_codes + 1
    default_candidates = default_candidates + #candidates
end
-- 不传限制值必须等价于显式传入 config.lua 的默认过滤值
assert(
    default_codes == filtered_codes,
    "省略限制值与显式传入默认值的编码数不一致"
)
assert(
    default_candidates == filtered_candidates,
    "省略限制值与显式传入默认值的候选数不一致"
)
local rank_file = assert(io.open(root .. "/lua/tiger_sentence/data/ranks.lua", "r"))
local rank_count = 0
for line in rank_file:lines() do
    if line:match('^  %[".-"%]=%d+,$') then
        rank_count = rank_count + 1
    end
end
assert(rank_file:close())
assert(rank_count == 20000, "字频条目总数偏离已审计基线")
assert(ranks.count == rank_count, "字频模块条目数不一致")
assert(ranks.rank("的") == 1, "首条字频排名错误")
assert(ranks.rank("镺") == ranks.count, "末条字频排名错误")
assert(ranks.rank("\0") == ranks.count + 1, "未知字频排名错误")

local context_composing = true
local push_allowed = true
local function get_property(self, name)
    return rawget(self, name) or ""
end
local context = {
    get_property = get_property,
    set_property = rawset,
    input = string.rep("a", 128),
    confirmed = 0,
    menu = true,
    clear = function(self)
        self.input = ""
    end,
    confirm_current_selection = function(self)
        self.confirmed = self.confirmed + 1
        self.input = ""
        return true
    end,
    get_option = function()
        return false
    end,
    has_menu = function(self)
        return self.menu
    end,
    is_composing = function()
        return context_composing
    end,
    push_input = function(self, value)
        if not push_allowed then
            return false
        end
        self.input = self.input .. value
        return true
    end,
}
local schema_defaults = { config = { get_int = function() end } }
local env = { engine = { context = context, schema = schema_defaults } }
local adapter = require("tiger_sentence.rime.adapter")
local quick_symbol = require("tiger_sentence.rime.quick_symbol")
local state_store = require("tiger_sentence.rime.state")

local translator_env = {
    engine = {
        context = {
            get_property = function(_, name)
                return context:get_property(name)
            end,
            set_property = function(_, name, value)
                context:set_property(name, value)
            end,
        },
    },
}
local other_env = {
    engine = { context = { get_property = get_property, set_property = rawset } },
}
local shared = state_store.get(env)
local other = state_store.get(other_env)
assert(state_store.get(translator_env) == shared and shared ~= other)
shared.committed_text = "反"
shared.empty_code_pending = { text = "反" }
other.committed_text = "保留"
collectgarbage("collect")
assert(state_store.get(translator_env).committed_text == "反")
state_store.reset(translator_env)
assert(state_store.get(env) == shared and shared.committed_text == "")
assert(shared.empty_code_pending == nil and other.committed_text == "保留")

local function key(representation)
    return {
        alt = function()
            return false
        end,
        caps = function()
            return false
        end,
        ctrl = function()
            return false
        end,
        release = function()
            return false
        end,
        shift = function()
            return false
        end,
        repr = function()
            return representation
        end,
        super = function()
            return false
        end,
    }
end

context.input = ""
context_composing = false
assert(adapter.processor(key("apostrophe"), env) == 2, "空闲引号没有交给 Rime 标点处理")
assert(context.input == "", "空闲引号进入了整句组合")
push_allowed = false
assert(adapter.processor(key("a"), env) == 2, "写入失败的按键没有交回后续处理器")
assert(context.input == "", "写入失败后组合输入发生变化")
push_allowed = true
context.input = string.rep("a", 128)
context_composing = true

assert(adapter.processor(key("a"), env) == 1)
assert(context.input == string.rep("a", 128), "128 码后仍接受普通编码")
for _, representation in ipairs({ "1", "semicolon", "apostrophe" }) do
    assert(adapter.processor(key(representation), env) == 1)
    assert(context.input == string.rep("a", 128), "上限处的选重键改写了输入")
end
adapter.deactivate(env)
context.input = string.rep("z", 128)
context.menu = false
assert(adapter.processor(key("1"), env) == 1)
assert(context.input == string.rep("z", 128), "无候选时选重键突破 128 码上限")
adapter.deactivate(env)
context.input = "xr"
state_store.get(env).committed_raw = string.rep("gyy", 43)
state_store.get(env).committed_text = string.rep("羊", 43)
assert(adapter.processor(key("x"), env) == 1)
assert(context.input == "xrx", "已提交历史错误占用了未上屏编码预算")
adapter.deactivate(env)

context.input = "notacode"
context_composing = true
context.menu = false
state_store.get(env).trackers = { keep = { text = "保留" } }
assert(adapter.processor(key("space"), env) == 1)
assert(context.input == "notacode", "无候选时空格改写了输入")
assert(next(state_store.get(env).trackers) == nil, "无候选时空格没有重置会话")
adapter.deactivate(env)

context.input = ""
context_composing = false
context.input = "ae"
context_composing = true
context.menu = true
assert(quick_symbol.func(key(";"), env) == 2 and context.input == "ae")
assert(adapter.processor(key(";"), env) == 1 and context.input == "ae;")
context.input = "ae"
assert(adapter.processor(key("'"), env) == 1 and context.input == "ae'")
adapter.deactivate(env)

context.input = "ae"
context_composing = true
context.menu = true
assert(adapter.processor(key("space"), env) == 1)
assert(context.confirmed == 1 and context.input == "", "空格没有确认当前候选")
assert(next(state_store.get(env).trackers) == nil, "空格确认后没有重置会话")

local highlighted = 0
local highlight_segment = {
    selected_index = 0,
    menu = {
        candidate_count = function()
            return 3
        end,
    },
}
local highlight_context = {
    get_property = get_property,
    set_property = rawset,
    input = "gyygch",
    composition = {
        empty = function()
            return false
        end,
        back = function()
            return highlight_segment
        end,
    },
    get_option = function()
        return false
    end,
    has_menu = function()
        return true
    end,
    highlight = function(_, index)
        highlighted = index
        highlight_segment.selected_index = index
        return true
    end,
    is_composing = function()
        return true
    end,
}
local highlight_env = { engine = { context = highlight_context, schema = schema_defaults } }
assert(adapter.processor(key("Tab"), highlight_env) == 1 and highlighted == 1)
assert(adapter.processor(key("Shift+Tab"), highlight_env) == 1 and highlighted == 0)
assert(state_store.get(highlight_env).suspended, "Tab 没有暂停提前上屏")
adapter.deactivate(highlight_env)

-- 绑定可能缺少高亮方法，或以返回 false 的兼容实现提供该方法
local native_highlight = highlight_context.highlight
for _, available in ipairs({ false, true }) do
    rawset(highlight_context, "highlight", available and function()
        return false
    end or nil)
    assert(adapter.processor(key("Tab"), highlight_env) == 1)
    assert(highlight_segment.selected_index == 1)
    assert(adapter.processor(key("Shift+Tab"), highlight_env) == 1)
    assert(highlight_segment.selected_index == 0)
    adapter.deactivate(highlight_env)
end
rawset(highlight_context, "highlight", native_highlight)

-- 高亮后继续输入字母固定该候选的文本与编码边界
highlight_context.input = "xr"
highlight_segment.selected_index = 0
rawset(highlight_segment.menu, "candidate_count", function()
    return 1
end)
assert(adapter.processor(key("Tab"), highlight_env) == 1)
assert(adapter.processor(key("x"), highlight_env) == 1)
local locked_state = state_store.get(highlight_env)
assert(#locked_state.locks == 1, "高亮后继续输入没有锁定候选")
assert(
    locked_state.locks[1].raw == "xr"
        and locked_state.locks[1].text == "反"
        and locked_state.locks[1].boundaries == "2,3;",
    "锁定边界不符"
)
assert(highlight_context.input == "xrx", "锁定后的组合输入不符")
assert(adapter.processor(key("BackSpace"), highlight_env) == 1)
assert(#locked_state.locks == 0, "退到锁定编码以内没有解锁")
assert(highlight_context.input == "xr", "解锁后的组合输入不符")
adapter.deactivate(highlight_env)
rawset(highlight_segment.menu, "candidate_count", function()
    return 3
end)

local committed = {}
---@type boolean|string
local reject_remainder = false
local rolling_input = ""
local rolling_context = {
    get_property = get_property,
    set_property = rawset,
    clear = function(self)
        self.input = ""
    end,
    get_option = function(_, name)
        return name == "tiger_sentence_early_commit"
            or name == "tiger_sentence_allow_duplicate_single"
    end,
    has_menu = function()
        return true
    end,
    is_composing = function(self)
        return self.input ~= ""
    end,
    push_input = function(self, value)
        self.input = self.input .. value
        return true
    end,
}
setmetatable(rolling_context, {
    __index = function(_, name)
        if name == "input" then
            return rolling_input
        end
    end,
    __newindex = function(_, name, value)
        assert(name == "input")
        if reject_remainder == "silent" then
            return
        end
        assert(not reject_remainder, "Rime 拒绝替换组合输入")
        rolling_input = value
    end,
})
local rolling_env = {
    engine = {
        context = rolling_context,
        schema = schema_defaults,
        commit_text = function(_, value)
            committed[#committed + 1] = value
        end,
    },
}
local early_commit_case = "awmenamcunta"
for index = 1, 8 do
    assert(adapter.processor(key(early_commit_case:sub(index, index)), rolling_env) == 1)
end
local pending_tracker = next(state_store.get(rolling_env).trackers)
assert(pending_tracker, "极强证据没有建立独立 tracker")
reject_remainder = true
local rebuilt, rebuild_error =
    pcall(adapter.processor, key(early_commit_case:sub(9, 9)), rolling_env)
assert(not rebuilt and tostring(rebuild_error):match("拒绝替换组合输入"))
assert(#committed == 0, "剩余输入重建失败后仍发生了不可逆提交")
assert(rolling_context.input == early_commit_case:sub(1, 8), "替换失败后原组合输入丢失")
reject_remainder = "silent"
rebuilt, rebuild_error = pcall(adapter.processor, key(early_commit_case:sub(9, 9)), rolling_env)
assert(not rebuilt and tostring(rebuild_error):match("拒绝替换组合输入"))
assert(#committed == 0 and rolling_context.input == early_commit_case:sub(1, 8))
adapter.deactivate(rolling_env)

-- 锁定候选时替换组合输入失败必须回滚锁定状态与已提交前缀
reject_remainder = false
rolling_context.input = "xr"
state_store.get(rolling_env).tab_pending = true
reject_remainder = true
local locked, lock_error = pcall(adapter.processor, key("x"), rolling_env)
assert(not locked and tostring(lock_error):match("拒绝替换组合输入"))
assert(#state_store.get(rolling_env).locks == 0, "替换失败后仍留下锁定状态")
assert(rolling_context.input == "xr", "替换失败后原组合输入丢失")
assert(state_store.get(rolling_env).committed_text == "", "替换失败后已提交前缀未回滚")
assert(#committed == 0, "替换失败后仍发生了提交")
adapter.deactivate(rolling_env)
reject_remainder = false
rolling_context.input = ""
committed = {}
for index = 1, #early_commit_case do
    assert(adapter.processor(key(early_commit_case:sub(index, index)), rolling_env) == 1)
end
assert(table.concat(committed) == "买")
assert(rolling_context.input == "enamcunta")

local function translate(input, target_env)
    local emitted = {}
    local original_candidate = rawget(_G, "Candidate")
    local original_yield = rawget(_G, "yield")
    rawset(_G, "Candidate", function(_, _, _, value)
        return { text = value }
    end)
    rawset(_G, "yield", function(candidate)
        emitted[#emitted + 1] = candidate
    end)
    local translated, translation_error = xpcall(function()
        adapter.translator(input, { start = 0, _end = #input }, target_env)
    end, debug.traceback)
    rawset(_G, "Candidate", original_candidate)
    rawset(_G, "yield", original_yield)
    assert(translated, translation_error)
    return emitted
end

local emitted = translate(rolling_context.input, rolling_env)
assert(#emitted > 0)
local full_result = require("tiger_sentence.decoder").decode_full(early_commit_case)
assert(table.concat(committed) .. emitted[1].text == full_result[1].text)
adapter.deactivate(rolling_env)

local high_frequency_limit = 1500
local allow_duplicate_single = true
local policy_env = {
    engine = {
        context = {
            get_property = get_property,
            set_property = rawset,
            get_option = function(_, name)
                return name == "tiger_sentence_allow_duplicate_single" and allow_duplicate_single
            end,
        },
        schema = {
            config = {
                get_int = function(_, name)
                    return name == "tiger_sentence/high_freq_limit" and high_frequency_limit or nil
                end,
            },
        },
    },
}
assert(#translate("aag", policy_env) == 0, "翻译器没有读取高频过滤配置")
high_frequency_limit = 0
assert(translate("aag", policy_env)[1].text == "书", "翻译器没有应用关闭的高频过滤")
allow_duplicate_single = false
assert(
    translate("gyygch", policy_env)[1].text == "羊赤",
    "翻译器没有读取单字重码开关"
)
allow_duplicate_single = true
assert(
    translate("gyygch", policy_env)[1].text == "羊羔",
    "翻译器没有应用单字重码开关"
)
local policy_config = policy_env.engine.schema.config
local get_int = policy_config.get_int
rawset(policy_config, "get_int", function()
    error("注入的配置读取错误")
end)
local config_ok, config_error = pcall(translate, "aag", policy_env)
rawset(policy_config, "get_int", get_int)
assert(not config_ok and tostring(config_error):find("注入的配置读取错误", 1, true))
local get_option = policy_env.engine.context.get_option
rawset(policy_env.engine.context, "get_option", function()
    error("注入的开关读取错误")
end)
local option_ok, option_error = pcall(translate, "aag", policy_env)
rawset(policy_env.engine.context, "get_option", get_option)
assert(not option_ok and tostring(option_error):find("注入的开关读取错误", 1, true))
adapter.deactivate(policy_env)

local function run_empty_code(minimum)
    local output = ""
    local empty_context = {
        get_property = get_property,
        set_property = rawset,
        input = "",
        clear = function(self)
            self.input = ""
        end,
        get_option = function(_, name)
            return name == "tiger_sentence_early_commit"
                or name == "tiger_sentence_allow_duplicate_single"
        end,
        has_menu = function()
            return true
        end,
        is_composing = function(self)
            return self.input ~= ""
        end,
        push_input = function(self, value)
            self.input = self.input .. value
            return true
        end,
    }
    local empty_env = {
        engine = {
            context = empty_context,
            schema = {
                config = {
                    get_int = function(_, name)
                        return name == "tiger_sentence/min_retained_raw_length" and minimum or nil
                    end,
                },
            },
            commit_text = function(_, value)
                output = output .. value
            end,
        },
    }
    for character in ("vuy"):gmatch(".") do
        assert(adapter.processor(key(character), empty_env) == 1)
    end
    adapter.deactivate(empty_env)
    return output, empty_context.input
end

local empty_output, empty_remainder = run_empty_code(0)
assert(empty_output == "这" and empty_remainder == "y", "空码自动上屏结果错误")
local retained_output, retained_input = run_empty_code(2)
assert(
    retained_output == "" and retained_input == "vuy",
    "最少保留编码没有门控空码上屏"
)
