-- 纯运行时模块共用的 UTF-8 与预编辑辅助函数
local M = {}

function M.normalize(raw)
    return raw:lower():gsub("%s+", "")
end

function M.has_letter(raw)
    return raw:find("%a") ~= nil
end

function M.chars(value)
    local result = {}
    for _, codepoint in utf8.codes(value) do
        result[#result + 1] = utf8.char(codepoint)
    end
    return result
end

function M.length(value)
    local length = utf8.len(value)
    assert(length, "UTF-8 编码无效")
    return length
end

function M.common_prefix(left, right)
    local common = {}
    local left_characters = M.chars(left)
    local right_characters = M.chars(right)
    for index = 1, math.min(#left_characters, #right_characters) do
        if left_characters[index] ~= right_characters[index] then
            break
        end
        common[index] = left_characters[index]
    end
    return table.concat(common)
end

function M.trim_segmented(segmented, raw_prefix_length)
    if segmented == "" or raw_prefix_length <= 0 then
        return segmented
    end
    local raw_count = 0
    local index = 1
    while index <= #segmented and raw_count < raw_prefix_length do
        if segmented:byte(index) ~= 32 then
            raw_count = raw_count + 1
        end
        index = index + 1
    end
    while index <= #segmented and segmented:byte(index) == 32 do
        index = index + 1
    end
    return index <= #segmented and segmented:sub(index) or ""
end

return M
