-- 每个进程只测一个场景，避免不同操作互相预热缓存
local function file_exists(path)
    local file = io.open(path, "rb")
    if not file then
        return false
    end
    file:close()
    return true
end

local function load_codes(path)
    local buckets = { {}, {}, {}, {} }
    local seen = {}
    local file = assert(io.open(path, "rb"), "无法读取码表：" .. path)
    for line in file:lines() do
        local code = line:match("^%S+%s+([a-z]+)")
        if code and #code >= 2 and #code <= 4 and not seen[code] then
            seen[code] = true
            buckets[#code][#buckets[#code] + 1] = code
        end
    end
    file:close()
    for length = 2, 4 do
        assert(#buckets[length] > 0, "码表缺少 " .. length .. " 码")
    end
    return buckets
end

local function build_corpus(buckets, count, input_length, initial_seed)
    local seed = initial_seed
    local seen = {}
    local corpus = {}
    local attempts = 0
    local function random(limit)
        seed = seed * 48271 % 2147483647
        return seed % limit + 1
    end
    while #corpus < count do
        attempts = attempts + 1
        assert(attempts <= count * 1000, "无法生成足够的不同合法输入")
        local parts = {}
        local remaining = input_length
        while remaining > 0 do
            local lengths = {}
            for length = 2, 4 do
                if length <= remaining and remaining - length ~= 1 then
                    lengths[#lengths + 1] = length
                end
            end
            local length = lengths[random(#lengths)]
            local codes = buckets[length]
            parts[#parts + 1] = codes[random(#codes)]
            remaining = remaining - length
        end
        local raw = table.concat(parts)
        if not seen[raw] then
            seen[raw] = true
            corpus[#corpus + 1] = raw
        end
    end
    return corpus
end

local function memory_mib(field)
    local file = io.open("/proc/self/status", "r")
    if not file then
        return nil
    end
    local status = file:read("*a")
    file:close()
    local kib = status:match(field .. ":%s+(%d+)%s+kB")
    return kib and tonumber(kib) / 1024 or nil
end

if arg[1] == "--self-test" then
    local codes_path = arg[2] or "dicts/tiger_sentence.codes.txt"
    local buckets = load_codes(codes_path)
    local first = build_corpus(buckets, 8, 14, 72631)
    local second = build_corpus(buckets, 8, 14, 72631)
    for index = 1, #first do
        assert(#first[index] == 14 and first[index]:match("^[a-z]+$"))
        assert(first[index] == second[index])
    end
    return
end

local root = arg[1] or "."
local operation = arg[2] or "incremental"
local input_length = arg[3] and assert(tonumber(arg[3]), "输入长度必须是数字") or 16
local iterations = arg[4] and assert(tonumber(arg[4]), "迭代次数必须是数字") or 300
local seed = arg[5] and assert(tonumber(arg[5]), "随机种子必须是数字") or 72631
local default_codes = root .. "/dicts/tiger_sentence.codes.txt"
local codes_path = arg[6]
    or (file_exists(default_codes) and default_codes or root .. "/tiger_sentence.codes.txt")
local high_frequency_limit = arg[7] and assert(tonumber(arg[7]), "高频限制必须是数字") or 0
local warmup_rounds = arg[8] and assert(tonumber(arg[8]), "预热轮数必须是数字") or 0

assert(
    operation == "full"
        or operation == "incremental"
        or operation == "early"
        or operation == "session",
    "操作必须是 full、incremental、early 或 session"
)
assert(
    input_length >= 2 and input_length <= 128 and input_length % 1 == 0,
    "输入长度必须是 2 到 128 的整数"
)
assert(iterations > 0 and iterations % 1 == 0, "迭代次数必须是正整数")
assert(seed > 0 and seed < 2147483647 and seed % 1 == 0, "随机种子必须是有效正整数")
assert(
    high_frequency_limit >= 0 and high_frequency_limit % 1 == 0,
    "高频限制必须是非负整数"
)
assert(warmup_rounds >= 0 and warmup_rounds % 1 == 0, "预热轮数必须是非负整数")

local corpus = build_corpus(load_codes(codes_path), iterations, input_length, seed)
package.path = root .. "/lua/?.lua;" .. package.path
rime_api = {
    get_user_data_dir = function()
        return root
    end,
    get_shared_data_dir = function()
        return root
    end,
}

local decoder = require("tiger_sentence.decoder")
local reset = decoder.reset
local model_status = require("tiger_sentence.model").status
local confidence = require("tiger_sentence.decoder.confidence")

local status = model_status()
assert(status.loaded, status.error or "整句模型加载失败")

-- 模拟 Rime 的 Lua 调用顺序；不计前端渲染及原生组件耗时
local session
if operation == "session" then
    local adapter = require("tiger_sentence.rime.adapter")
    local quick_symbol = require("tiger_sentence.rime.quick_symbol")
    local visible = {}
    local context = {
        input = "",
        get_property = function(self, name)
            return rawget(self, name) or ""
        end,
        set_property = rawset,
        get_option = function(_, name)
            return name == "tiger_sentence_early_commit"
                or name == "tiger_sentence_allow_duplicate_single"
        end,
        clear = function(self)
            self.input = ""
        end,
        is_composing = function(self)
            return self.input ~= ""
        end,
        has_menu = function()
            return #visible > 0
        end,
        push_input = function(self, value)
            self.input = self.input .. value
            return true
        end,
        confirm_current_selection = function(self)
            if #visible == 0 then
                return false
            end
            self.input = ""
            return true
        end,
    }
    local env = {
        engine = {
            context = context,
            schema = {
                config = {
                    get_int = function(_, name)
                        if name == "tiger_sentence/high_freq_limit" then
                            return high_frequency_limit
                        end
                        return 0
                    end,
                },
            },
            commit_text = function() end,
        },
    }
    rawset(_G, "Candidate", function(_, _, _, value)
        return { text = value }
    end)
    rawset(_G, "yield", function(candidate)
        visible[#visible + 1] = candidate
    end)
    local function key(representation)
        local function no()
            return false
        end
        return {
            repr = function()
                return representation
            end,
            release = no,
            shift = no,
            caps = no,
            ctrl = no,
            alt = no,
            super = no,
        }
    end
    local keys = {}
    for character in ("abcdefghijklmnopqrstuvwxyz"):gmatch(".") do
        keys[character] = key(character)
    end
    local space, escape = key("space"), key("Escape")
    session = function(raw)
        for character in raw:gmatch(".") do
            local event = keys[character]
            if quick_symbol.func(event, env) == 2 then
                assert(adapter.processor(event, env) == 1, "编码未被处理器接收")
            end
            visible = {}
            adapter.translator(context.input, { start = 0, _end = #context.input }, env)
        end
        if adapter.processor(space, env) == 2 or context.input ~= "" then
            adapter.processor(escape, env)
        end
        assert(context.input == "", "提交或取消后组合未结束")
    end
end

local function run_corpus()
    local calls = 0
    for _, raw in ipairs(corpus) do
        reset()
        if session then
            session(raw)
            calls = calls + #raw
        elseif operation == "full" then
            decoder.decode_full(raw, false, "", true, high_frequency_limit)
            calls = calls + 1
        else
            local include_early_commit = operation == "early"
            for length = 1, #raw do
                local result = decoder.decode(
                    raw:sub(1, length),
                    include_early_commit,
                    "",
                    true,
                    high_frequency_limit
                )
                if
                    include_early_commit
                    and not result.confidence_truncated
                    and not result.early_commit_confidence_truncated
                then
                    confidence.prefixes(
                        result.early_commit_uses_incomplete_tail and result.early_commit_candidates
                            or result,
                        "",
                        0.99999
                    )
                end
                calls = calls + 1
            end
        end
    end
    return calls
end

for _ = 1, warmup_rounds do
    run_corpus()
end
reset()
collectgarbage("collect")
local heap_before = collectgarbage("count") / 1024
local rss_before = memory_mib("VmRSS")
local started = os.clock()
local calls = run_corpus()
local elapsed = os.clock() - started
local peak_rss = memory_mib("VmHWM")
collectgarbage("collect")
local heap_after = collectgarbage("count") / 1024
local rss_after = memory_mib("VmRSS")

io.write(
    "operation\tlength\tinputs\twarmups\tcalls\tseconds\tus_per_call\theap_before_mib\theap_after_mib\trss_before_mib\trss_after_mib\tpeak_rss_mib\n"
)
io.write(
    string.format(
        "%s\t%d\t%d\t%d\t%d\t%.6f\t%.3f\t%.3f\t%.3f\t%s\t%s\t%s\n",
        operation,
        input_length,
        iterations,
        warmup_rounds,
        calls,
        elapsed,
        elapsed * 1000000 / calls,
        heap_before,
        heap_after,
        rss_before and string.format("%.3f", rss_before) or "NA",
        rss_after and string.format("%.3f", rss_after) or "NA",
        peak_rss and string.format("%.3f", peak_rss) or "NA"
    )
)
