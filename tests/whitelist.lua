-- 使用公开码表验证白名单的增删、路径选择、格式与文件故障
local root = assert(arg[1])
package.path = root .. "/lua/?.lua;" .. package.path
local module_path = root .. "/lua/tiger_sentence/data/lexicon.lua"
local load_lexicon = assert(loadfile(module_path))
local temporary = os.tmpname()
local path = temporary .. ".white"
local open = io.open
local directory = root
rime_api = {
    get_user_data_dir = function()
        return directory
    end,
}
rawset(io, "open", function(name, mode)
    if name == root .. "/tiger_sentence.full_code_whitelist.txt" then
        return open(path, mode)
    end
    return open(name, mode)
end)
local function write(value)
    local file = assert(open(path, "wb"))
    assert(file:write(value))
    assert(file:close())
end
local function rejects(expected)
    local ok, message = pcall(load_lexicon)
    assert(not ok and tostring(message):find(expected, 1, true), tostring(message))
end
local absent = load_lexicon()
local code, character
for candidate_code, candidates in absent.entries(0) do
    if #candidate_code > 1 and not absent.lookup(candidate_code, 1500) then
        for _, candidate in ipairs(candidates) do
            if utf8.len(candidate.t) == 1 then
                code, character = candidate_code, candidate.t
                break
            end
        end
    end
    if code then
        break
    end
end
assert(code and character, "公开码表缺少可测试的过滤编码")
write("\239\187\191# 注释\r\n " .. character .. " \r" .. character .. "\n")
assert(load_lexicon().lookup(code, 1500)[1].t == character)
write("")
assert(not load_lexicon().lookup(code, 1500), "删除白名单条目后仍放行")
write("\255")
rejects("白名单 UTF-8 编码无效")
write(character)
local intercepted = io.open
for _, operation in ipairs({ "open", "read", "close" }) do
    rawset(io, "open", function(name, mode)
        if name ~= root .. "/tiger_sentence.full_code_whitelist.txt" then
            return open(name, mode)
        end
        if operation == "open" then
            return nil, "白名单权限错误", 13
        end
        local file = assert(open(path, mode))
        return {
            read = function()
                if operation == "read" then
                    return nil, "白名单读取错误"
                end
                return file:read("*a")
            end,
            close = function()
                assert(file:close())
                if operation == "close" then
                    return nil, "白名单关闭错误"
                end
                return true
            end,
        }
    end)
    rejects("白名单")
end
io.open = intercepted
directory = ""
assert(not load_lexicon().lookup(code, 1500))
rawset(rime_api, "get_user_data_dir", function()
    error("目录 API 故障")
end)
rejects("目录 API 故障")
rime_api = nil
assert(not load_lexicon().lookup(code, 1500))
io.open = open
assert(os.remove(path))
assert(os.remove(temporary))
