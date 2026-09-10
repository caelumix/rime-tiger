-- 在同一组公开数据上比较完整解码、增量编辑与参考结果
local root, reference, corpus_path = assert(arg[1]), assert(arg[2]), assert(arg[3])
package.path = root .. "/lua/?.lua;" .. package.path
rime_api = {
    get_user_data_dir = function()
        return root
    end,
    get_shared_data_dir = function()
        return root
    end,
}
local mode = arg[4]
---@type any
local reference_backend = mode ~= "current"
        and assert(loadfile(reference .. "/lua/tiger_sentence.lua"))()
    or nil
local decoder = mode ~= "reference_backend" and require("tiger_sentence.decoder") or nil
if mode then
    local high_frequency_limit = tonumber(arg[5]) or 0
    local backend = assert(mode == "reference_backend" and reference_backend or decoder)
    local reset = backend.reset or backend.reset_decode_cache
    if mode == "reference_backend" then
        backend.apply_high_freq_limit(high_frequency_limit)
    end
    local samples = { append = {}, edit = {} }
    local function measure(raw, category)
        local started = os.clock()
        backend.decode(raw, false, "", true, high_frequency_limit)
        local values = samples[category]
        values[#values + 1] = (os.clock() - started) * 1000000
    end
    for raw in io.lines(corpus_path) do
        if #raw <= 128 then
            reset()
            for length = 1, #raw do
                measure(raw:sub(1, length), "append")
            end
            for length = #raw - 1, 1, -1 do
                measure(raw:sub(1, length), "edit")
            end
        end
    end
    local file = assert(io.open("/proc/self/status"))
    local status = assert(file:read("*a"))
    file:close()
    local peak = assert(tonumber(status:match("VmHWM:%s+(%d+)"))) / 1024
    local fields = {}
    for _, category in ipairs({ "append", "edit" }) do
        local values = samples[category]
        local total = 0
        for _, value in ipairs(values) do
            total = total + value
        end
        table.sort(values)
        fields[#fields + 1] = string.format(
            '"%s":{"calls":%d,"mean_us":%.3f,"p50_us":%.3f,"p95_us":%.3f}',
            category,
            #values,
            total / #values,
            values[math.ceil(#values * 0.5)],
            values[math.ceil(#values * 0.95)]
        )
    end
    io.write('{"peak_rss_mib":', peak, ",", table.concat(fields, ","), "}\n")
    return
end
assert(decoder)
local lexicon = require("tiger_sentence.data.lexicon")
local count, edits, reference_backend_edit_errors = 0, 0, 0
local edit_failures = {}
local function equal(left, right, diagnose)
    if #left ~= #right then
        return false
    end
    for index, a in ipairs(left) do
        local b = right[index]
        for _, field in ipairs({ "text", "segmented", "max_rank", "supplement_score" }) do
            if a[field] ~= b[field] then
                if diagnose then
                    io.stderr:write(
                        index,
                        " ",
                        field,
                        " ",
                        tostring(a[field]),
                        " != ",
                        tostring(b[field]),
                        "\n"
                    )
                end
                return false
            end
        end
        for _, field in ipairs({ "score", "confidence_score" }) do
            if math.abs(a[field] - b[field]) > 1e-9 then
                if diagnose then
                    io.stderr:write(
                        index,
                        " ",
                        field,
                        " ",
                        tostring(a[field]),
                        " != ",
                        tostring(b[field]),
                        "\n"
                    )
                end
                return false
            end
        end
    end
    return true
end
local corpus = {}
for raw in io.lines(corpus_path) do
    corpus[#corpus + 1] = raw
end
for _, limit in ipairs({ 0, 1500 }) do
    reference_backend.apply_high_freq_limit(limit)
    for _, duplicate in ipairs({ false, true }) do
        reference_backend.set_allow_duplicate_single({
            get_option = function()
                return duplicate
            end,
        })
        for code in lexicon.entries(limit) do
            local left = decoder.decode_full(code, false, "", duplicate, limit)
            assert(
                equal(left, reference_backend.decode_full(code)),
                "参考整码候选不一致：" .. code
            )
            count = count + 1
        end
        for _, raw in ipairs(corpus) do
            if #raw <= 128 then
                decoder.reset()
                reference_backend.reset_decode_cache()
                local sequence = {}
                for length = 1, #raw do
                    sequence[#sequence + 1] = raw:sub(1, length)
                end
                for length = #raw - 1, 1, -1 do
                    sequence[#sequence + 1] = raw:sub(1, length)
                end
                sequence[#sequence + 1] = raw .. "a"
                sequence[#sequence + 1] = "xrxbj"
                for _, input in ipairs(sequence) do
                    if #input <= 128 then
                        local full = decoder.decode_full(input, false, "", duplicate, limit)
                        assert(
                            equal(full, reference_backend.decode_full(input), true),
                            "参考完整解码不一致："
                                .. input
                                .. "，过滤 "
                                .. limit
                                .. "，重码 "
                                .. tostring(duplicate)
                        )
                        assert(
                            equal(full, decoder.decode(input, false, "", duplicate, limit)),
                            "本地编辑缓存不一致：" .. input
                        )
                        if not equal(full, reference_backend.decode(input)) then
                            reference_backend_edit_errors = reference_backend_edit_errors + 1
                            edit_failures[#edit_failures + 1] = string.format(
                                '{"input":%q,"limit":%d,"duplicate":%s}',
                                input,
                                limit,
                                tostring(duplicate)
                            )
                        end
                        count = count + 1
                        edits = edits + 1
                    end
                end
            end
        end
    end
end
io.write(
    string.format(
        '{"comparisons":%d,"edit_steps":%d,"reference_backend_cache_mismatches":%d,"edit_failures":[%s]}\n',
        count,
        edits,
        reference_backend_edit_errors,
        table.concat(edit_failures, ",")
    )
)
