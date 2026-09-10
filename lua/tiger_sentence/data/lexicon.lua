-- 读取由 tools/build_data.lua 生成的紧凑整句词典
local config = require("tiger_sentence.config")
local ranks = require("tiger_sentence.data.ranks")

local MAGIC = "TCSLEX04"
local HEADER_SIZE = 32
local ALWAYS_ALLOWED = 1
local OPTIMAL_SINGLE = 2

local function data_path()
    local source = package.searchpath("tiger_sentence.data.lexicon", package.path)
    ---@cast source string
    return (source:gsub("%.lua$", ".bin", 1))
end

local function read_all(path)
    local file = assert(io.open(path, "rb"), "无法打开整句词典：" .. path)
    local value = assert(file:read("*a"), "无法读取整句词典：" .. path)
    assert(file:close())
    return value
end

local function load_whitelist()
    local values = {}
    if not rime_api then
        return values
    end
    local directory = rime_api.get_user_data_dir()
    if directory == "" then
        return values
    end
    local path = directory .. "/tiger_sentence.full_code_whitelist.txt"
    local file, open_error, code = io.open(path, "rb")
    if not file and code == 2 then
        return values
    end
    assert(file, open_error)
    local content, read_error = file:read("*a")
    local closed, close_error = file:close()
    assert(content, read_error)
    assert(closed, close_error)
    content = content:gsub("^\239\187\191", ""):gsub("\r\n", "\n"):gsub("\r", "\n")
    local number = 0
    for line in (content .. "\n"):gmatch("(.-)\n") do
        number = number + 1
        line = line:match("^%s*(.-)%s*$")
        if line ~= "" and line:sub(1, 1) ~= "#" then
            assert(utf8.len(line), "白名单 UTF-8 编码无效：" .. path .. ":" .. number)
            for _, point in utf8.codes(line) do
                values[utf8.char(point)] = true
            end
        end
    end
    return values
end

local bytes = read_all(data_path())
local magic, header_size, file_size, code_count, candidate_count, code_width =
    string.unpack("<c8I4I8I4I4I4", bytes)
assert(magic == MAGIC, "整句词典格式错误")
assert(header_size == HEADER_SIZE, "整句词典头长度错误")
assert(file_size == #bytes, "整句词典大小不匹配")
local index_width = code_width + 6
local data_offset = HEADER_SIZE + code_count * index_width
assert(data_offset <= #bytes, "整句词典索引已截断")
local whitelist = load_whitelist()
local lookup_cache = {}
local lookup_keys = {}
local lookup_next = 1
local lookup_limit

local lengths = {}
local function index_entry(index)
    local position = HEADER_SIZE + index * index_width + 1
    local code, offset, count = string.unpack("<c" .. code_width .. "I4I2", bytes, position)
    return code:match("^[a-z]+"), offset, count
end

local entries_by_code = {}
local seen_lengths = {}
for index = 0, code_count - 1 do
    local code, offset, count = index_entry(index)
    entries_by_code[code] = (offset << 16) | count
    if not seen_lengths[#code] then
        seen_lengths[#code] = true
        lengths[#lengths + 1] = #code
    end
end

table.sort(lengths)

local function lookup(code, high_frequency_limit)
    local limit = high_frequency_limit == nil and config.high_frequency_limit
        or math.max(0, math.floor(high_frequency_limit))
    limit = math.min(limit, ranks.count)
    if lookup_limit ~= limit then
        lookup_cache = {}
        lookup_keys = {}
        lookup_next = 1
        lookup_limit = limit
    end
    local cached = lookup_cache[code]
    if cached then
        return cached
    end
    local entry = entries_by_code[code]
    if not entry then
        return nil
    end
    local position = data_offset + (entry >> 16) + 1
    local candidates = {}
    for _ = 1, entry & 0xffff do
        local rank, text_length, frequency_rank, flags
        rank, text_length, frequency_rank, flags, position =
            string.unpack("<I2I2I2B", bytes, position)
        local text_end = position + text_length - 1
        assert(text_end <= #bytes, "整句词典候选已截断")
        if flags & ALWAYS_ALLOWED ~= 0 or limit == 0 or frequency_rank > limit
            or whitelist[bytes:sub(position, text_end)] then
            candidates[#candidates + 1] = {
                t = bytes:sub(position, text_end),
                r = rank,
                o = flags & OPTIMAL_SINGLE ~= 0 or nil,
            }
        end
        position = text_end + 1
    end
    local result = #candidates > 0 and candidates or nil
    if not result then
        return nil
    end
    local old_key = lookup_keys[lookup_next]
    if old_key then
        lookup_cache[old_key] = nil
    end
    lookup_cache[code] = result
    lookup_keys[lookup_next] = code
    lookup_next = lookup_next % config.lexicon_cache_entries + 1
    return result
end

-- 判断编码是否为某个更长有效编码的真前缀
local function has_proper_prefix(prefix, high_frequency_limit)
    local low, high = 0, code_count
    while low < high do
        local middle = low + math.floor((high - low) / 2)
        local current = index_entry(middle)
        if current <= prefix then
            low = middle + 1
        else
            high = middle
        end
    end
    while low < code_count do
        local current = index_entry(low)
        if current:sub(1, #prefix) ~= prefix then
            return false
        end
        if lookup(current, high_frequency_limit) then
            return true
        end
        low = low + 1
    end
    return false
end

local function entries(high_frequency_limit)
    local index = 0
    return function()
        while index < code_count do
            local code = index_entry(index)
            index = index + 1
            local candidates = lookup(code, high_frequency_limit)
            if candidates then
                return code, candidates
            end
        end
        return nil
    end
end

return {
    candidate_count = candidate_count,
    code_count = code_count,
    entries = entries,
    has_proper_prefix = has_proper_prefix,
    lengths = lengths,
    lookup = lookup,
}
