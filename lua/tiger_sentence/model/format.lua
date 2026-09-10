-- 校验 TCSKNM02 二进制格式并加载常驻索引
-- 查询缓存与概率计算由 tiger_sentence.model.kn 负责
local M = {}

local MAGIC = "TCSKNM02"
local HEADER_SIZE = 104

function M.read_at(file, offset, count)
    assert(file:seek("set", offset), "无法定位 n-gram 文件")
    local value = file:read(count)
    assert(value and #value == count, "移动 n-gram 文件已截断")
    return value
end

function M.valid_probability(value)
    return value == value and value >= 0 and value <= 1
end

local function checked_end(offset, count, width, header_size, file_size, label)
    assert(offset >= header_size, label .. "起点位于文件头内")
    local section_end = offset + count * width
    assert(section_end >= offset and section_end <= file_size, label .. "超出文件大小")
    return section_end
end

local function validate_unigrams(data, count)
    local previous_key = nil
    for index = 0, count - 1 do
        local key, probability = string.unpack("<i4f", data, index * 8 + 1)
        assert(not previous_key or key > previous_key, "一元组键未严格递增")
        assert(M.valid_probability(probability), "一元组概率无效")
        previous_key = key
    end
end

local function validate_index(data, count, section_start, section_end, label)
    local previous_key = nil
    local previous_offset = nil
    for index = 0, count - 1 do
        local key, offset = string.unpack("<I8I8", data, index * 16 + 1)
        assert(not previous_key or key > previous_key, label .. "键未严格递增")
        assert(offset >= section_start and offset < section_end, label .. "页偏移超出范围")
        assert(not previous_offset or offset > previous_offset, label .. "页偏移未严格递增")
        previous_key = key
        previous_offset = offset
    end
end

local function unpack_header(header, path)
    assert(
        header and #header >= 8 and header:sub(1, 8) == MAGIC,
        "不是 TCSKNM02 模型：" .. path
    )
    assert(#header == HEADER_SIZE, "移动 n-gram 文件已截断：" .. path)

    local fields = {
        string.unpack("<I4I4I8I4I4I4I4I8I4I4I8I8I8I4I4I8I8", header, 9),
    }
    return {
        version = fields[1],
        header_size = fields[2],
        file_size = fields[3],
        index_stride = fields[4],
        unigram_count = fields[6],
        unigram_offset = fields[8],
        bigram_context_count = fields[9],
        bigram_index_count = fields[10],
        bigram_blocks_offset = fields[11],
        bigram_index_offset = fields[12],
        trigram_context_count = fields[13],
        trigram_index_count = fields[14],
        trigram_blocks_offset = fields[16],
        trigram_index_offset = fields[17],
    }
end

local function validate_layout(file, header)
    assert(
        header.version == 1 and header.header_size == HEADER_SIZE,
        "不支持此移动 n-gram 版本"
    )
    assert(header.index_stride >= 16, "移动 n-gram 索引步长无效")
    assert(
        header.bigram_blocks_offset < header.bigram_index_offset
            and header.bigram_index_offset < header.trigram_blocks_offset
            and header.trigram_blocks_offset < header.trigram_index_offset,
        "移动三元组布局无效"
    )
    assert(file:seek("end") == header.file_size, "移动 n-gram 文件大小不匹配")

    local unigram_end = checked_end(
        header.unigram_offset,
        header.unigram_count,
        8,
        header.header_size,
        header.file_size,
        "一元组区段"
    )
    local bigram_index_end = checked_end(
        header.bigram_index_offset,
        header.bigram_index_count,
        16,
        header.header_size,
        header.file_size,
        "二元组索引"
    )
    checked_end(
        header.trigram_index_offset,
        header.trigram_index_count,
        16,
        header.header_size,
        header.file_size,
        "三元组索引"
    )
    assert(unigram_end <= header.bigram_blocks_offset, "一元组区段重叠")
    assert(bigram_index_end <= header.trigram_blocks_offset, "二元组索引重叠")
    assert(
        header.bigram_index_count == math.ceil(header.bigram_context_count / header.index_stride),
        "二元组索引数量不匹配"
    )
    assert(
        header.trigram_index_count == math.ceil(header.trigram_context_count / header.index_stride),
        "三元组索引数量不匹配"
    )
end

function M.load(file, path)
    local header = unpack_header(file:read(HEADER_SIZE), path)
    validate_layout(file, header)

    local unigrams = M.read_at(file, header.unigram_offset, header.unigram_count * 8)
    local bigram_index = M.read_at(file, header.bigram_index_offset, header.bigram_index_count * 16)
    local trigram_index =
        M.read_at(file, header.trigram_index_offset, header.trigram_index_count * 16)
    assert(#unigrams >= 8, "移动 n-gram 缺少未知一元组")
    assert(string.unpack("<i4", unigrams, 1) == 0, "移动 n-gram 未知一元组键无效")
    validate_unigrams(unigrams, header.unigram_count)
    validate_index(
        bigram_index,
        header.bigram_index_count,
        header.bigram_blocks_offset,
        header.bigram_index_offset,
        "二元组索引"
    )
    validate_index(
        trigram_index,
        header.trigram_index_count,
        header.trigram_blocks_offset,
        header.trigram_index_offset,
        "三元组索引"
    )

    return {
        file_size = header.file_size,
        index_stride = header.index_stride,
        unigrams = unigrams,
        unigram_count = header.unigram_count,
        unknown = string.unpack("<f", unigrams, 5),
        contexts = {
            b = {
                kind = "b",
                count = header.bigram_context_count,
                index = bigram_index,
                index_count = header.bigram_index_count,
                section_end = header.bigram_index_offset,
            },
            t = {
                kind = "t",
                count = header.trigram_context_count,
                index = trigram_index,
                index_count = header.trigram_index_count,
                section_end = header.trigram_index_offset,
            },
        },
    }
end

M.magic = MAGIC

return M
