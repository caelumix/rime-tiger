-- 采用分页 I/O 与有界缓存的纯 Lua Kneser-Ney 读取器
local format = require("tiger_sentence.model.format")

local BOS = "\2"
local EOS = "\3"
local SHIFT = 2097152
local PAGE_CACHE_BYTES = 2 * 1024 * 1024
local CONTEXT_CACHE_ENTRIES = 16384

---@class TigerSentenceKnModel
---@field path string
---@field bytes integer
---@field format string
---@field logp fun(previous2: string, previous1: string, target: string): number
---@field has_observed_bigram fun(previous: string, target: string): boolean
---@field close fun()

local M = { BOS = BOS, EOS = EOS }

local function file_exists(path)
    local file = io.open(path, "rb")
    if not file then
        return false
    end
    file:close()
    return true
end

local function candidate_paths()
    local paths = {}
    if not rime_api then
        return paths
    end
    local user_dir = rime_api.get_user_data_dir and rime_api.get_user_data_dir()
    local shared_dir = rime_api.get_shared_data_dir and rime_api.get_shared_data_dir()
    if user_dir and user_dir ~= "" then
        paths[#paths + 1] = user_dir .. "/models/sentence-ngram-mobile.bin"
        paths[#paths + 1] = user_dir .. "/sentence-ngram-mobile.bin"
    end
    if shared_dir and shared_dir ~= "" then
        paths[#paths + 1] = shared_dir .. "/models/sentence-ngram-mobile.bin"
    end
    return paths
end

local function scalar(token)
    return utf8.codepoint(token)
end

local function pack2(first, second)
    return first * SHIFT + second % SHIFT
end

local function new_context_cache()
    return { values = {}, keys = {}, next = 1 }
end

local function reset_caches(store)
    store.pages = {}
    store.page_bytes = 0
    store.lru_head = nil
    store.lru_tail = nil
    store.context_caches = {
        b = new_context_cache(),
        t = new_context_cache(),
    }
end

local function unlink_page(store, entry)
    if entry.previous then
        entry.previous.next = entry.next
    else
        store.lru_head = entry.next
    end
    if entry.next then
        entry.next.previous = entry.previous
    else
        store.lru_tail = entry.previous
    end
end

local function touch_page(store, entry)
    if store.lru_head == entry then
        return
    end
    if entry.previous or entry.next or store.lru_tail == entry then
        unlink_page(store, entry)
    end
    entry.previous = nil
    entry.next = store.lru_head
    if store.lru_head then
        store.lru_head.previous = entry
    else
        store.lru_tail = entry
    end
    store.lru_head = entry
end

local function index_key(context, index)
    return string.unpack("<I8", context.index, index * 16 + 1)
end

local function find_page(context, key)
    local low, high = 0, context.index_count
    while low < high do
        local middle = low + math.floor((high - low) / 2)
        if index_key(context, middle) <= key then
            low = middle + 1
        else
            high = middle
        end
    end
    return low - 1
end

local function page_offsets(context, page)
    local offset = string.unpack("<I8", context.index, page * 16 + 9)
    local next_offset = context.section_end
    if page + 1 < context.index_count then
        next_offset = string.unpack("<I8", context.index, (page + 1) * 16 + 9)
    end
    return offset, next_offset
end

local function get_page(store, context, page)
    local cache_key = context.kind .. page
    local entry = store.pages[cache_key]
    if entry then
        touch_page(store, entry)
        return entry.data
    end

    local offset, next_offset = page_offsets(context, page)
    local byte_count = next_offset - offset
    local data = format.read_at(store.file, offset, byte_count)
    -- 保持原有大页兼容性，但不让单页撑大常驻缓存
    if byte_count > PAGE_CACHE_BYTES then
        return data
    end
    entry = { key = cache_key, data = data, bytes = #data }
    store.pages[cache_key] = entry
    store.page_bytes = store.page_bytes + entry.bytes
    touch_page(store, entry)

    while store.page_bytes > PAGE_CACHE_BYTES do
        local victim = store.lru_tail
        unlink_page(store, victim)
        store.pages[victim.key] = nil
        store.page_bytes = store.page_bytes - victim.bytes
    end
    return data
end

local function lookup_unigram(store, key)
    local low, high = 0, store.layout.unigram_count
    local data = store.layout.unigrams
    while low < high do
        local middle = low + math.floor((high - low) / 2)
        if string.unpack("<i4", data, middle * 8 + 1) < key then
            low = middle + 1
        else
            high = middle
        end
    end
    if low < store.layout.unigram_count then
        local position = low * 8 + 1
        if string.unpack("<i4", data, position) == key then
            return string.unpack("<f", data, position + 4)
        end
    end
    return store.layout.unknown
end

local function find_successor(data, position, count, target)
    local low, high = 0, count
    while low < high do
        local middle = low + math.floor((high - low) / 2)
        if string.unpack("<I4", data, position + middle * 8) < target then
            low = middle + 1
        else
            high = middle
        end
    end
    if low < count then
        local at = position + low * 8
        if string.unpack("<I4", data, at) == target then
            return string.unpack("<f", data, at + 4), true
        end
    end
    return 0.0, false
end

local function validate_successors(data, position, count)
    local previous_target = nil
    for successor = 0, count - 1 do
        local target, probability = string.unpack("<I4f", data, position + successor * 8)
        assert(not previous_target or target > previous_target, "n-gram 后继项未严格递增")
        assert(format.valid_probability(probability), "n-gram 后继项概率无效")
        previous_target = target
    end
end

local function remember_context(cache, key, value)
    local old_key = cache.keys[cache.next]
    if old_key ~= nil then
        cache.values[old_key] = nil
    end
    cache.values[key] = value
    cache.keys[cache.next] = key
    cache.next = cache.next % CONTEXT_CACHE_ENTRIES + 1
end

local function lookup_cached_context(store, context, cached, target)
    if cached.missing then
        return 1.0, 0.0, false
    end
    local data = get_page(store, context, cached.page)
    local probability, observed =
        find_successor(data, cached.successor_position, cached.successor_count, target)
    return cached.lambda, probability, observed
end

local function scan_context_page(store, context, cache, page, key, target)
    local data = get_page(store, context, page)
    local position = 1
    local remaining =
        math.min(store.layout.index_stride, context.count - page * store.layout.index_stride)
    local previous_context = nil

    for context_index = 1, remaining do
        assert(position + 15 <= #data, "n-gram 上下文已截断")
        local context_key, lambda, successor_count
        context_key, lambda, successor_count, position = string.unpack("<I8fI4", data, position)
        assert(
            not previous_context or context_key > previous_context,
            "n-gram 上下文未严格递增"
        )
        if context_index == 1 then
            assert(context_key == index_key(context, page), "n-gram 页键与索引不匹配")
        end
        assert(format.valid_probability(lambda), "n-gram 回退权重无效")
        assert(position + successor_count * 8 - 1 <= #data, "n-gram 后继项已截断")

        if context_key == key then
            validate_successors(data, position, successor_count)
            remember_context(cache, key, {
                page = page,
                lambda = lambda,
                successor_count = successor_count,
                successor_position = position,
            })
            local probability, observed = find_successor(data, position, successor_count, target)
            return lambda, probability, observed
        end
        if context_key > key then
            remember_context(cache, key, { missing = true })
            return 1.0, 0.0, false
        end
        previous_context = context_key
        position = position + successor_count * 8
    end

    assert(position == #data + 1, "n-gram 页含有尾随数据")
    remember_context(cache, key, { missing = true })
    return 1.0, 0.0, false
end

local function lookup_context(store, kind, key, target)
    local context = store.layout.contexts[kind]
    local cache = store.context_caches[kind]
    local cached = cache.values[key]
    if cached then
        return lookup_cached_context(store, context, cached, target)
    end

    local page = find_page(context, key)
    if page < 0 then
        remember_context(cache, key, { missing = true })
        return 1.0, 0.0, false
    end
    return scan_context_page(store, context, cache, page, key, target)
end

local function probability(store, previous2, previous1, target)
    local first = scalar(previous2)
    local second = scalar(previous1)
    local third = scalar(target)
    local unigram = lookup_unigram(store, third)
    local bigram_lambda, bigram_probability = lookup_context(store, "b", second, third)
    local bigram = bigram_probability + bigram_lambda * unigram
    local trigram_lambda, trigram_probability =
        lookup_context(store, "t", pack2(first, second), third)
    return trigram_probability + trigram_lambda * bigram
end

---@return TigerSentenceKnModel
local function load_file(file, path)
    local layout = format.load(file, path)
    local store = { file = file, layout = layout }
    local closed = false
    reset_caches(store)

    return {
        path = path,
        bytes = layout.file_size,
        format = format.magic,
        logp = function(previous2, previous1, target)
            return math.log(math.max(probability(store, previous2, previous1, target), 1e-300))
        end,
        has_observed_bigram = function(previous, target)
            local _, _, observed = lookup_context(store, "b", scalar(previous), scalar(target))
            return observed
        end,
        close = function()
            if closed then
                return
            end
            closed = true
            reset_caches(store)
            assert(file:close())
        end,
    }
end

---@return TigerSentenceKnModel
function M.load(path)
    local file = assert(io.open(path, "rb"), "无法打开 n-gram：" .. path)
    local ok, result = pcall(load_file, file, path)
    if not ok then
        pcall(file.close, file)
        error(result, 0)
    end
    return result
end

---@return TigerSentenceKnModel|nil, string|nil
function M.try_load()
    local failures = {}
    for _, path in ipairs(candidate_paths()) do
        if file_exists(path) then
            local ok, model = pcall(M.load, path)
            if ok then
                return model, nil
            end
            failures[#failures + 1] = path .. "：" .. tostring(model)
        end
    end
    if #failures > 0 then
        return nil, table.concat(failures, " | ")
    end
    return nil, "未找到整句 n-gram 模型"
end

return M
