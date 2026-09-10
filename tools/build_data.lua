-- 从明文数据生成紧凑整句词典和字频模块
assert(
    #arg <= 4,
    "用法：tools/build_data.lua [码表 [字频 [二进制词典 [字频模块]]]]"
)
local codes_path = arg[1] or "dicts/tiger_sentence.codes.txt"
local ranks_path = arg[2] or "dicts/tiger_sentence.char_ranks.txt"
local lexicon_path = arg[3] or "lua/tiger_sentence/data/lexicon.bin"
local ranks_output_path = arg[4] or "lua/tiger_sentence/data/ranks.lua"

local LEXICON_MAGIC = "TCSLEX04"
local LEXICON_HEADER_SIZE = 32
local ALWAYS_ALLOWED = 1
local OPTIMAL_SINGLE = 2

local function read_lines(path, callback, optional)
    local file, open_error, error_code = io.open(path, "rb")
    if not file and optional and error_code == 2 then
        return
    end
    assert(file, open_error)
    local content = assert(file:read("*a"), "无法读取数据文件：" .. path)
    assert(file:close())
    content = content:gsub("^\239\187\191", ""):gsub("\r\n", "\n"):gsub("\r", "\n")
    local line_number = 0
    for raw_line in (content .. "\n"):gmatch("(.-)\n") do
        line_number = line_number + 1
        callback(raw_line, line_number)
    end
end

local function read_codes(path)
    local entries = {}
    local seen = {}
    read_lines(path, function(line, line_number)
        line = line:match("^%s*(.-)%s*$")
        if line ~= "" and line:sub(1, 1) ~= "#" then
            local value, code = line:match("^(%S+)%s+(%S+)%s*$")
            code = code and code:lower()
            assert(
                value and utf8.len(value) and code:match("^[a-z]+$"),
                "码表条目格式错误：" .. line_number
            )
            local key = value .. "\0" .. code
            if not seen[key] then
                seen[key] = true
                entries[#entries + 1] = { text = value, code = code }
            end
        end
    end)
    assert(#entries > 0, "码表不含有效条目：" .. path)
    return entries
end

local function read_ranks(path)
    local ordered, ranks = {}, {}
    read_lines(path, function(line, line_number)
        line = line:match("^%s*(.-)%s*$")
        if line ~= "" and line:sub(1, 1) ~= "#" then
            assert(utf8.len(line) == 1, "字频条目必须是单个字符：" .. line_number)
            local character = line
            if not ranks[character] then
                ordered[#ordered + 1] = character
                ranks[character] = #ordered
            end
        end
    end, true)
    return ordered, ranks
end

local function is_single(value)
    return utf8.len(value) == 1
end

local function build_index(entries, ranks, unknown_frequency_rank)
    local codes, character_codes = {}, {}
    for _, entry in ipairs(entries) do
        local candidates = codes[entry.code]
        if not candidates then
            candidates = {}
            codes[entry.code] = candidates
        end
        local candidate = { text = entry.text, rank = #candidates + 1 }
        candidates[#candidates + 1] = candidate
        if is_single(entry.text) then
            local values = character_codes[entry.text]
            if not values then
                values = {}
                character_codes[entry.text] = values
            end
            values[#values + 1] = { code = entry.code, rank = candidate.rank }
        end
    end

    local optimal, primary = {}, {}
    for character, values in pairs(character_codes) do
        local best_first, best_any, shortest
        for _, value in ipairs(values) do
            if not shortest or #value.code < #shortest then
                shortest = value.code
            end
            if #value.code >= 2 then
                if not best_any or #value.code < #best_any then
                    best_any = value.code
                end
                if value.rank == 1 and (not best_first or #value.code < #best_first) then
                    best_first = value.code
                end
            end
        end
        optimal[character] = shortest
        primary[character] = best_first or best_any
    end

    for code, candidates in pairs(codes) do
        for _, candidate in ipairs(candidates) do
            local always_allowed = #code == 1
                or not is_single(candidate.text)
                or primary[candidate.text] == code
            candidate.flags = always_allowed and ALWAYS_ALLOWED or 0
            if optimal[candidate.text] == code then
                candidate.flags = candidate.flags | OPTIMAL_SINGLE
            end
            candidate.frequency_rank = ranks[candidate.text] or unknown_frequency_rank
        end
    end
    return codes
end

local function render_lexicon(codes, candidate_count)
    local code_width = 1
    local sorted_codes = {}
    for code in pairs(codes) do
        code_width = math.max(code_width, #code)
        sorted_codes[#sorted_codes + 1] = code
    end
    table.sort(sorted_codes)

    local index, data, data_offset = {}, {}, 0
    for code_index, code in ipairs(sorted_codes) do
        local candidates = codes[code]
        assert(#candidates <= 65535, "单个编码的候选过多：" .. code)
        index[code_index] =
            string.pack("<c" .. code_width .. "I4I2", code, data_offset, #candidates)
        for _, candidate in ipairs(candidates) do
            assert(#candidate.text <= 65535, "候选文本过长：" .. code)
            local packed = string.pack(
                "<I2I2I2B",
                candidate.rank,
                #candidate.text,
                candidate.frequency_rank,
                candidate.flags
            ) .. candidate.text
            data[#data + 1] = packed
            data_offset = data_offset + #packed
        end
    end
    local file_size = LEXICON_HEADER_SIZE + #sorted_codes * (code_width + 6) + data_offset
    local header = string.pack(
        "<c8I4I8I4I4I4",
        LEXICON_MAGIC,
        LEXICON_HEADER_SIZE,
        file_size,
        #sorted_codes,
        candidate_count,
        code_width
    )
    return header .. table.concat(index) .. table.concat(data)
end

local function render_ranks(ordered)
    local lines = {
        "-- 由 tools/build_data.lua 根据字频表生成",
        string.format("local UNKNOWN = %d", #ordered + 1),
        "local ranks = {",
    }
    for rank, character in ipairs(ordered) do
        lines[#lines + 1] = string.format("  [%q]=%d,", character, rank)
    end
    lines[#lines + 1] = "}"
    lines[#lines + 1] = "local M = {}"
    lines[#lines + 1] = "M.count = UNKNOWN - 1"
    lines[#lines + 1] = "function M.rank(ch)"
    lines[#lines + 1] = "    return ranks[ch] or UNKNOWN"
    lines[#lines + 1] = "end"
    lines[#lines + 1] = "return M"
    return table.concat(lines, "\n") .. "\n"
end

local function write_temporary(path, value)
    local temporary_path = path .. ".tmp"
    local stale = io.open(temporary_path, "r")
    if stale then
        stale:close()
        error("临时输出已存在：" .. temporary_path, 0)
    end
    local output = assert(io.open(temporary_path, "wb"))
    local ok, write_error = xpcall(function()
        assert(output:write(value))
        assert(output:close())
    end, debug.traceback)
    if not ok then
        pcall(output.close, output)
        os.remove(temporary_path)
        error(write_error, 0)
    end
    return temporary_path
end

local function file_exists(path)
    local file = io.open(path, "rb")
    if not file then
        return false
    end
    file:close()
    return true
end

local function move_aside(path)
    local backup_path = path .. ".bak"
    assert(not file_exists(backup_path), "备份输出已存在：" .. backup_path)
    if not file_exists(path) then
        return false, backup_path
    end
    local moved, move_error = os.rename(path, backup_path)
    assert(moved, move_error)
    return true, backup_path
end

local function rollback_target(path, moved, backup_path, installed)
    local failures = {}
    if installed then
        local removed, remove_error = os.remove(path)
        if not removed and file_exists(path) then
            failures[#failures + 1] = tostring(remove_error)
        end
    end
    if moved then
        local restored, restore_error = os.rename(backup_path, path)
        if not restored then
            failures[#failures + 1] = tostring(restore_error)
        end
    end
    return table.concat(failures, " | ")
end

local entries = read_codes(codes_path)
local ordered_ranks, ranks = read_ranks(ranks_path)
local codes = build_index(entries, ranks, #ordered_ranks + 1)
local targets = {
    { path = lexicon_path, value = render_lexicon(codes, #entries) },
    { path = ranks_output_path, value = render_ranks(ordered_ranks) },
}
local prepared, prepare_error = xpcall(function()
    for _, target in ipairs(targets) do
        target.temporary = write_temporary(target.path, target.value)
    end
end, debug.traceback)
if not prepared then
    for _, target in ipairs(targets) do
        if target.temporary then
            os.remove(target.temporary)
        end
    end
    error(prepare_error, 0)
end
local installed, install_error = xpcall(function()
    for _, target in ipairs(targets) do
        target.moved, target.backup = move_aside(target.path)
    end
    for _, target in ipairs(targets) do
        local renamed, rename_error = os.rename(target.temporary, target.path)
        assert(renamed, rename_error)
        target.installed = true
    end
end, debug.traceback)
if not installed then
    local rollback_errors = {}
    for index = #targets, 1, -1 do
        local target = targets[index]
        local rollback_error =
            rollback_target(target.path, target.moved, target.backup, target.installed)
        if rollback_error ~= "" then
            rollback_errors[#rollback_errors + 1] = rollback_error
        end
        os.remove(target.temporary)
    end
    assert(#rollback_errors == 0, "码表回滚失败：" .. table.concat(rollback_errors, " | "))
    error(install_error, 0)
end
for _, target in ipairs(targets) do
    if target.moved then
        assert(os.remove(target.backup))
    end
end
