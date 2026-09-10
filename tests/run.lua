-- 将测试临时文件限制在检查目录内，并记录实际触发的错误分支
local script, root = assert(arg[1]), assert(arg[2])
local temporary_index = 0
rawset(os, "tmpname", function()
    temporary_index = temporary_index + 1
    local path = root .. "/scratch-" .. temporary_index
    local file = assert(io.open(path, "wb"))
    assert(file:close())
    return path
end)
local original_assert, original_error = assert, error
local failures = {}
local function record()
    local caller = debug.getinfo(3, "Sl")
    local source = caller.source:gsub("^@", "")
    if source:find("/lua/tiger_sentence/", 1, true) or source:match("tools/build_data%.lua$") then
        local relative = source:sub(1, #root + 1) == root .. "/" and source:sub(#root + 2) or source
        local key = relative .. ":" .. caller.currentline
        failures[key] = (failures[key] or 0) + 1
    end
end
_G.assert = function(value, ...)
    if not value then
        record()
    end
    return original_assert(value, ...)
end
_G.error = function(message, level)
    record()
    return original_error(message, level == 0 and 0 or (level or 1) + 1)
end
arg = { root }
local ok, message = xpcall(assert(loadfile(script)), debug.traceback)
local output = assert(io.open(root .. "/errors.tsv", "a"))
for key, count in pairs(failures) do
    output:write(key, "\t", count, "\n")
end
assert(output:close())
if not ok then
    original_error(message, 0)
end
