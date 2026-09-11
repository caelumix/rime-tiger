-- 通过实际文件和 I/O 故障验证二进制边界与生成事务
local root = assert(arg[1])
package.path = root .. "/lua/?.lua;" .. package.path
local reader = require("tiger_sentence.model.kn")
local format = require("tiger_sentence.model.format")
local temporary = os.tmpname()
local function write(path, value)
    local file = assert(io.open(path, "wb"))
    assert(file:write(value))
    assert(file:close())
end
local function fails(callback, expected)
    local ok, message = pcall(callback)
    assert(not ok and tostring(message):find(expected, 1, true), tostring(message))
end
local function page(key)
    return string.pack("<I8fI4I4f", key, 0.5, 1, 1, 0.5)
end
local function fixture(pages, contexts)
    pages = pages or { page(2) }
    local data, index, offset = {}, {}, 120
    for number, value in ipairs(pages) do
        data[#data + 1] = value
        index[#index + 1] = string.pack("<I8I8", number + 1, offset)
        offset = offset + #value
    end
    local bi_index, tri = offset, offset + #pages * 16
    local fields = {
        1,
        104,
        tri + 40,
        16,
        0,
        2,
        0,
        104,
        contexts or (#pages - 1) * 16 + 1,
        #pages,
        120,
        bi_index,
        1,
        1,
        0,
        tri,
        tri + 24,
    }
    return "TCSKNM02"
        .. string.pack("<I4I4I8I4I4I4I4I8I4I4I8I8I8I4I4I8I8", table.unpack(fields))
        .. string.pack("<i4fi4f", 0, 0.5, 2, 0.5)
        .. table.concat(data)
        .. table.concat(index)
        .. page(2)
        .. string.pack("<I8I8", 2, tri)
end
local function patch(value, offset, encoding, replacement)
    local bytes = string.pack(encoding, replacement)
    return value:sub(1, offset - 1) .. bytes .. value:sub(offset + #bytes)
end
local function reject(value, expected, query)
    write(temporary, value)
    fails(function()
        local model = reader.load(temporary)
        if query then
            local ok, message = pcall(model.logp, reader.BOS, query, "\1")
            model.close()
            assert(ok, message)
        else
            model.close()
        end
    end, expected)
end
local valid = fixture()
-- 损坏的用户模型可回退到共享模型，全部失败时保留路径和原因
local saved_api = rime_api
local model_directory = root .. "/lua/tiger_sentence/data"
local broken_model = model_directory .. "/sentence-ngram-mobile.bin"
write(broken_model, "INVALID!")
rime_api = {
    get_user_data_dir = function()
        return model_directory
    end,
    get_shared_data_dir = function()
        return root
    end,
}
local fallback = assert(reader.try_load())
assert(fallback.path == root .. "/models/sentence-ngram-mobile.bin")
fallback.close()
rawset(rime_api, "get_shared_data_dir", function()
    return model_directory
end)
local absent, load_error = reader.try_load()
assert(load_error)
assert(
    not absent and load_error:find(broken_model, 1, true) and load_error:find("TCSKNM02", 1, true)
)
assert(os.remove(broken_model))
rime_api = saved_api
for _, test in ipairs({
    { 9, "I4", 2, "版本" },
    { 25, "I4", 1, "索引步长" },
    { 17, "I8", #valid + 1, "文件大小" },
    { 41, "I8", 100, "文件头" },
    { 33, "I4", 1000, "超出文件" },
    { 33, "I4", 3, "区段重叠" },
    { 53, "I4", 2, "索引重叠" },
    { 49, "I4", 17, "二元组索引数量" },
    { 73, "I8", 17, "三元组索引数量" },
    { 33, "I4", 0, "缺少未知一元组" },
    { 153, "I8", 119, "页偏移超出范围" },
}) do
    reject(patch(valid, test[1], "<" .. test[2], test[3]), test[4])
end
local two = fixture({ page(2), page(3) })
reject(patch(two, 185, "<I8", 2), "键未严格递增")
reject(patch(two, 193, "<I8", 120), "页偏移未严格递增")
reject(fixture({ "short" }), "上下文已截断", reader.BOS)
reject(fixture({ page(3) }), "页键与索引不匹配", reader.BOS)
reject(fixture({ string.pack("<I8fI4", 2, -1, 0) }), "回退权重", reader.BOS)
reject(fixture({ string.pack("<I8fI4", 2, 0.5, 2) }), "后继项已截断", reader.BOS)
reject(
    fixture({ string.pack("<I8fI4I4fI4f", 2, 0.5, 2, 1, 0.5, 1, 0.5) }),
    "后继项未严格递增",
    reader.BOS
)
reject(fixture({ page(2) .. page(2) }, 2), "上下文未严格递增", "甲")
reject(fixture({ page(2) .. "extra" }), "尾随数据", "甲")
fails(function()
    reader.load(temporary .. ".missing")
end, "无法打开")
fails(function()
    format.read_at({
        seek = function()
            return nil
        end,
    }, 0, 1)
end, "无法定位")
fails(function()
    format.read_at({
        seek = function()
            return 0
        end,
        read = function()
            return ""
        end,
    }, 0, 1)
end, "已截断")

local codes, ranks = temporary .. ".codes", temporary .. ".ranks"
local binary, output = temporary .. ".bin", temporary .. ".lua"
local arguments = arg
arg = { codes, ranks, binary, output }
local function build()
    dofile(root .. "/tools/build_data.lua")
end
arg[1] = codes .. ".missing"
fails(build, arg[1])
arg[1] = codes
write(ranks, "字\n")
for _, test in ipairs({
    { '# version: "20260101"\n', "不含有效条目" },
    { '# version: "20260101"\n' .. string.rep("字", 22000) .. "\taa\n", "文本过长" },
}) do
    write(codes, test[1])
    fails(build, test[2])
end
write(codes, '# version: "20260101"\n字\taa\n')
write(ranks, "")
build()
assert(assert(loadfile(output))().count == 0, "空字频没有关闭过滤")
assert(os.remove(ranks))
build()
assert(assert(loadfile(output))().count == 0, "缺失字频没有关闭过滤")
local saved_ranks = package.loaded["tiger_sentence.data.ranks"]
package.loaded["tiger_sentence.data.ranks"] = assert(loadfile(output))()
local empty_rank_model = assert(loadfile(root .. "/lua/tiger_sentence/model.lua"))()
assert(empty_rank_model.reference_isolation_penalty("龘") == 0)
package.loaded["tiger_sentence.data.ranks"] = saved_ranks
write(ranks, "字\n")
write(binary .. ".tmp", "占用")
fails(build, "临时输出已存在")
assert(os.remove(binary .. ".tmp"))
write(binary .. ".bak", "占用")
fails(build, "备份输出已存在")
assert(os.remove(binary .. ".bak"))
build()
local open = io.open
for _, operation in ipairs({ "read", "write", "close" }) do
    rawset(io, "open", function(path, mode)
        local file, message, code = open(path, mode)
        local target = operation == "read" and codes or binary .. ".tmp"
        if not file or path ~= target or (operation ~= "read" and mode ~= "wb") then
            return file, message, code
        end
        return setmetatable({}, {
            __index = function(_, name)
                return function(_, ...)
                    if name == operation then
                        file:close()
                        return nil, "注入的 " .. operation .. " 故障"
                    end
                    return file[name](file, ...)
                end
            end,
        })
    end)
    fails(build, operation == "read" and "无法读取" or "注入的")
    io.open = open
end
arg = arguments
-- 文件系统故障必须经过实际生成入口，并验证回滚路径
arg = { codes, ranks, binary, output, "extra" }
fails(build, "用法")
arg = { codes, ranks, binary, output }
write(codes, '# version: "20260101"\n字\t' .. string.rep("a", 33) .. "\n")
build()
local handle = assert(io.open(binary, "rb"))
local rendered = assert(handle:read("*a"))
handle:close()
assert(string.unpack("<I4", rendered, 29) == 33, "长编码被截断")
local entries = { '# version: "20260101"' }
for index = 1, 65536 do
    entries[#entries + 1] = tostring(index) .. "\taa"
end
write(codes, table.concat(entries, "\n"))
fails(build, "候选过多")
write(codes, '# version: "20260101"\n字\taa\n')
local rename, remove = os.rename, os.remove
for _, operation in ipairs({ "open", "close", "move", "rollback", "cleanup" }) do
    rawset(io, "open", function(path, mode)
        if operation == "open" and path == binary .. ".tmp" and mode == "wb" then
            return nil, "注入的创建故障"
        end
        local file, message, code = open(path, mode)
        if operation ~= "close" or path ~= codes or not file then
            return file, message, code
        end
        return {
            read = function(_, ...)
                return file:read(...)
            end,
            close = function()
                file:close()
                return nil, "注入的关闭故障"
            end,
        }
    end)
    rawset(os, "rename", function(from, to)
        if
            (operation == "move" and to == binary .. ".bak")
            or (operation == "rollback" and (from == output .. ".tmp" or from == binary .. ".bak"))
        then
            return nil, "注入的移动故障"
        end
        return rename(from, to)
    end)
    rawset(os, "remove", function(path)
        if operation == "cleanup" and path == binary .. ".bak" then
            return nil, "注入的清理故障"
        end
        return remove(path)
    end)
    fails(build, operation == "rollback" and "回滚失败" or "注入的")
    io.open, os.rename, os.remove = open, rename, remove
    for _, target in ipairs({ binary, output }) do
        remove(target .. ".tmp")
        remove(target .. ".bak")
    end
    build()
end
-- 文件代理模拟真实读取/关闭失败，不构造引擎不可能提供的对象状态
local function faulty_file(path, operation, callback)
    rawset(io, "open", function(name, mode)
        local file, message, code = open(name, mode)
        if name ~= path or not file then
            return file, message, code
        end
        return setmetatable({}, {
            __index = function(_, key)
                return function(_, ...)
                    if key == operation then
                        file:close()
                        return nil, "注入的文件故障"
                    end
                    return file[key](file, ...)
                end
            end,
        })
    end)
    fails(callback, operation == "read" and "无法读取" or "注入的文件故障")
    io.open = open
end
write(temporary, valid)
faulty_file(temporary, "close", function()
    reader.load(temporary).close()
end)
local lexicon_path = root .. "/lua/tiger_sentence/data/lexicon.bin"
local file = assert(open(lexicon_path, "rb"))
local lexicon_bytes = assert(file:read("*a"))
file:close()
local load_lexicon = assert(loadfile(root .. "/lua/tiger_sentence/data/lexicon.lua"))
local function with_lexicon(value, callback)
    write(lexicon_path, value)
    local ok, message = xpcall(callback, debug.traceback)
    write(lexicon_path, lexicon_bytes)
    assert(ok, message)
end
with_lexicon(rendered, function()
    local loaded = load_lexicon()
    assert(loaded.lengths[1] == 33 and loaded.lookup(string.rep("a", 33), 0)[1].t == "字")
    assert(loaded.has_proper_prefix(string.rep("a", 32), 0), "长编码前缀未保留")
end)
for _, test in ipairs({
    { 1, "c8", "INVALID!", "格式错误" },
    { 1, "c8", "TCSLEX03", "格式错误" },
    { 9, "I4", 0, "头长度" },
    { 13, "I8", 0, "大小不匹配" },
    { 21, "I4", 1000000, "索引已截断" },
}) do
    with_lexicon(patch(lexicon_bytes, test[1], "<" .. test[2], test[3]), function()
        fails(load_lexicon, test[4])
    end)
end
local count = string.unpack("<I4", lexicon_bytes, 21)
local width = string.unpack("<I4", lexicon_bytes, 29)
local data_start = 32 + count * (width + 6) + 1
local shortened = patch(lexicon_bytes:sub(1, data_start + 6), 13, "<I8", data_start + 6)
shortened = patch(shortened, data_start + 2, "<I2", 65535)
with_lexicon(shortened, function()
    fails(function()
        load_lexicon().lookup("a", 0)
    end, "候选已截断")
end)
for _, operation in ipairs({ "read", "close" }) do
    faulty_file(lexicon_path, operation, load_lexicon)
end
rawset(io, "open", function(path, mode)
    if path == lexicon_path then
        return nil, "注入的文件故障"
    end
    return open(path, mode)
end)
fails(load_lexicon, "无法打开")
io.open = open
fails(function()
    require("tiger_sentence.text").length("\255")
end, "UTF-8 编码无效")
arg = arguments
for _, path in ipairs({ temporary, codes, ranks, binary, output }) do
    assert(os.remove(path))
end
