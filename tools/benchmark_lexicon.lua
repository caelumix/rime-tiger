-- 仅供消融测量，在相同解码器下比较紧凑存储与明文全量加载
local root, mode, corpus = assert(arg[1]), assert(arg[2]), assert(arg[3])
package.path = root .. "/lua/?.lua;" .. package.path
rime_api = {
    get_user_data_dir = function()
        return root
    end,
    get_shared_data_dir = function()
        return root
    end,
}

local function load_text()
    local config = require("tiger_sentence.config")
    require("tiger_sentence.data.ranks")
    -- 复用生成器的解析和码位规则，仅截取无文件写入的构建部分
    local file = assert(io.open("tools/build_data.lua"))
    local source = assert(file:read("*a"))
    assert(file:close())
    local boundary = assert(source:find("local function render_lexicon", 1, true))
    local loader = source:sub(1, boundary - 1)
        .. [[
local entries = read_codes(codes_path)
local ordered, ranks = read_ranks(ranks_path)
local codes = build_index(entries, ranks, #ordered + 1)
return codes, #ordered, #entries
]]
    local environment = setmetatable({
        arg = {
            root .. "/tiger_sentence.codes.txt",
            root .. "/tiger_sentence.char_ranks.txt",
        },
    }, { __index = _G })
    local codes, rank_count, candidate_count =
        assert(load(loader, "text_lexicon", "t", environment))()
    local parser_file = assert(io.open(root .. "/lua/tiger_sentence/data/lexicon.lua"))
    local parser_source = assert(parser_file:read("*a"))
    assert(parser_file:close())
    local parser_start = assert(parser_source:find("local function load_whitelist()", 1, true))
    local parser_end = assert(parser_source:find("local bytes = read_all(data_path())", 1, true))
    local whitelist =
        assert(load(parser_source:sub(parser_start, parser_end - 1) .. "return load_whitelist()"))()
    local ordered, lengths, seen = {}, {}, {}
    for code, candidates in pairs(codes) do
        ordered[#ordered + 1] = code
        if not seen[#code] then
            seen[#code] = true
            lengths[#lengths + 1] = #code
        end
        for _, candidate in ipairs(candidates) do
            candidate.t, candidate.r = candidate.text, candidate.rank
            candidate.text, candidate.rank = nil, nil
            candidate.o = candidate.flags & 2 ~= 0 or nil
        end
    end
    table.sort(ordered)
    table.sort(lengths)
    local cache, previous_limit = {}, nil
    local function lookup(code, limit)
        limit = math.min(rank_count, math.max(0, math.floor(limit or config.high_frequency_limit)))
        if previous_limit ~= limit then
            cache, previous_limit = {}, limit
        end
        if cache[code] then
            return cache[code]
        end
        local values = codes[code]
        if not values then
            return nil
        end
        local selected = {}
        for _, candidate in ipairs(values) do
            if
                candidate.flags & 1 ~= 0
                or limit == 0
                or candidate.frequency_rank > limit
                or whitelist[candidate.t]
            then
                selected[#selected + 1] = candidate
            end
        end
        if #selected > 0 then
            cache[code] = selected
            return selected
        end
        return nil
    end
    return {
        lengths = lengths,
        candidate_count = candidate_count,
        code_count = #ordered,
        lookup = lookup,
        entries = function(limit)
            local index = 0
            return function()
                while index < #ordered do
                    index = index + 1
                    local code = ordered[index]
                    local candidates = lookup(code, limit)
                    if candidates then
                        return code, candidates
                    end
                end
                return nil
            end
        end,
        has_proper_prefix = function(prefix, limit)
            local low, high = 1, #ordered + 1
            while low < high do
                local middle = (low + high) // 2
                if ordered[middle] <= prefix then
                    low = middle + 1
                else
                    high = middle
                end
            end
            while low <= #ordered and ordered[low]:sub(1, #prefix) == prefix do
                if lookup(ordered[low], limit) then
                    return true
                end
                low = low + 1
            end
            return false
        end,
    }
end

local module = "tiger_sentence.data.lexicon"
if mode == "check" then
    local binary = require(module)
    local plain
    if arg[4] then
        package.path = arg[4] .. "/lua/?.lua;" .. package.path
        plain = assert(loadfile(arg[4] .. "/lua/tiger_sentence/data/lexicon.lua"))()
    else
        plain = load_text()
    end
    local count = 0
    for _, limit in ipairs({ 0, 1500 }) do
        local next_plain = plain.entries(limit)
        for code, candidates in binary.entries(limit) do
            local other_code, other = next_plain()
            assert(other)
            assert(code == other_code and #candidates == #other, code)
            for index, candidate in ipairs(candidates) do
                for _, field in ipairs({ "t", "r", "o" }) do
                    assert(candidate[field] == other[index][field], code .. ":" .. field)
                end
            end
            for length = 1, #code do
                local prefix = code:sub(1, length)
                assert(
                    binary.has_proper_prefix(prefix, limit)
                        == plain.has_proper_prefix(prefix, limit),
                    prefix
                )
            end
            count = count + 1
        end
        assert(next_plain() == nil)
    end
    io.write('{"codes_compared":', count, "}\n")
    return
end
assert(mode == "binary" or mode == "text")
collectgarbage("collect")
local before = collectgarbage("count")
local started = os.clock()
local lexicon = mode == "binary" and require(module) or load_text()
package.loaded[module] = lexicon
local elapsed = (os.clock() - started) * 1000
collectgarbage("collect")
local heap = (collectgarbage("count") - before) / 1024
io.write(string.format('{"load_ms":%.3f,"retained_heap_mib":%.3f,"typing":', elapsed, heap))
arg = { root, root, corpus, "current", arg[4] }
assert(loadfile("tests/comparison.lua"))()
io.write("}\n")
