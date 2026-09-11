-- 检验解码增量、候选窗口、码表等级选重、Beam 剪枝与置信度边界
local root = arg[1] or "."

package.path = root .. "/lua/?.lua;" .. package.path
rime_api = {
    get_user_data_dir = function()
        return root
    end,
    get_shared_data_dir = function()
        return root
    end,
}

local beam = require("tiger_sentence.decoder.beam")
local confidence = require("tiger_sentence.decoder.confidence")
local config = require("tiger_sentence.config")
local supplement = require("tiger_sentence.decoder.supplement")
local load_default = supplement.load_default
rawset(supplement, "load_default", function()
    return supplement.load(root .. "/tiger_sentence.supplement.example.txt")
end)
local decoder = require("tiger_sentence.decoder")
rawset(supplement, "load_default", load_default)
local lexicon = require("tiger_sentence.data.lexicon")
local model = require("tiger_sentence.model")
local status = model.status()
assert(status.loaded, status.error or "模型不可用")
assert(status.bytes == 224475584, "模型大小偏离已审计基线")

assert(lexicon.has_proper_prefix("v"), "有效尾码前缀未命中")
assert(not lexicon.has_proper_prefix("zzzz"), "完整四码被误作未完成尾码")

local function assert_candidate_equal(left, right, label)
    assert(left.text == right.text, label .. "：文本")
    assert(left.segmented == right.segmented, label .. "：切分")
    assert(left.score == right.score, label .. "：分数")
    assert(left.confidence_score == right.confidence_score, label .. "：置信度")
    assert(left.supplement_score == right.supplement_score, label .. "：补充奖励")
    assert(left.max_rank == right.max_rank, label .. "：码位")
end

local function assert_equal(left, right, label, ignore_early_commit)
    assert(#left == #right, label .. "：候选数量")
    assert(
        (left.confidence_truncated or false) == (right.confidence_truncated or false),
        label .. "：截断标志"
    )
    if not ignore_early_commit then
        assert(
            left.early_commit_uses_incomplete_tail == right.early_commit_uses_incomplete_tail,
            label .. "：尾码标志"
        )
        assert(
            left.early_commit_confidence_truncated == right.early_commit_confidence_truncated,
            label .. "：尾码截断标志"
        )
    end
    for index = 1, #left do
        assert_candidate_equal(left[index], right[index], label .. "：可见候选 " .. index)
    end
    if not ignore_early_commit then
        assert(
            #left.early_commit_candidates == #right.early_commit_candidates,
            label .. "：尾码候选数量"
        )
        for index = 1, #left.early_commit_candidates do
            assert_candidate_equal(
                left.early_commit_candidates[index],
                right.early_commit_candidates[index],
                label .. "：尾码候选 " .. index
            )
        end
    end
end

local function contains(candidates, value, segmented)
    for index = 1, #candidates do
        local candidate = candidates[index]
        if candidate.text == value and candidate.segmented == segmented then
            return true
        end
    end
    return false
end

for code, candidates in lexicon.entries() do
    for index = 1, #candidates do
        local candidate = candidates[index]
        local rank = candidate.r
        local selectors = { tostring(rank) }
        if rank == 2 then
            selectors[#selectors + 1] = ";"
        elseif rank == 3 then
            selectors[#selectors + 1] = "'"
        elseif rank == 10 then
            selectors[#selectors + 1] = "0"
        end
        if rank > 1 then
            for selector_index = 1, #selectors do
                local raw = code .. selectors[selector_index]
                assert(
                    contains(decoder.decode_full(raw), candidate.t, raw),
                    string.format(
                        "码表等级选重不可达：%s（%s，等级 %d）",
                        raw,
                        candidate.t,
                        rank
                    )
                )
            end
        end
    end
end
assert(decoder.decode_full("a;")[1].text == "那个")
assert(decoder.decode_full("gch;")[1].text == "声孩子")
assert(decoder.decode_full("aks3")[1].text == "𲈵")
assert(decoder.decode_full("fdvi4")[1].text == "蠃")
assert(decoder.decode_full("jtgo;")[1].text == "凭自己")
assert(decoder.has_complete_candidate("jtgo;gyy", "凭自己"))
assert(#decoder.decode_full("jtgo;gyy", false, "凭自己") > 0)
assert(decoder.decode_full("ae1")[1].text == "闲")
assert(decoder.decode_full("ae00")[1].text == "闲", "全零串没有采用隐式排序")
assert(decoder.decode_full("ae01")[1].text == "闲", "前导零没有采用数字选重")
local supplemented = decoder.decode_full("lccpf")
assert(supplemented[1].text == "茧师" and supplemented[1].supplement_score > 0)
assert(
    math.abs(
        supplemented[1].score - supplemented[1].confidence_score - supplemented[1].supplement_score
    ) < 1e-12,
    "补充奖励污染了原模型置信度"
)
local visible_tail = decoder.decode_full("awmen")
local early_tail = decoder.decode_full("awmen", true)
assert_equal(visible_tail, early_tail, "尾码扩展保持可见候选", true)
assert(early_tail.early_commit_uses_incomplete_tail, "合法未完成尾码未参与提前上屏")
assert(#early_tail.early_commit_candidates > #early_tail, "未完成尾码没有扩展置信池")
local boundary_evidence = decoder.decode_full("awmenam", true)
local boundary_prefixes = confidence.prefixes(
    boundary_evidence.early_commit_candidates,
    "",
    config.early_commit_closed_boundary_threshold
)
local buy_dou_boundaries = {}
for _, prefix in ipairs(boundary_prefixes) do
    if prefix.text == "买窦" then
        buy_dou_boundaries[prefix.raw_length] = true
    end
end
assert(
    buy_dou_boundaries[6] and buy_dou_boundaries[7],
    "相同文本的不同原始边界被合并"
)
decoder.reset()
decoder.decode("awmen")
assert(
    decoder.decode("awmen", true).early_commit_uses_incomplete_tail,
    "普通缓存阻止了尾码置信度计算"
)

local simplified_words = decoder.decode_full("aaaaa")
local has_implicit_nonfirst_word = false
for index = 1, #simplified_words do
    if simplified_words[index].text:find("静静", 1, true) then
        has_implicit_nonfirst_word = true
        break
    end
end
assert(not has_implicit_nonfirst_word, "非首选简词没有要求显式选重")
local explicit_word = decoder.decode_full("aa;aaa")[1]
assert(explicit_word.text:find("静静", 1, true), "显式简词选重失效")
assert(explicit_word.max_rank == 2, "显式选重没有保留码表名次")
for index = 1, #simplified_words do
    for piece in simplified_words[index].segmented:gmatch("%S+") do
        assert(#piece > 1, "长整句错误拆出裸一码字")
    end
end

assert(decoder.decode_full("gyygch", false, "", true)[1].text == "羊羔")
assert(decoder.decode_full("gyygch", false, "", false)[1].text == "羊赤")
assert(#decoder.decode_full("aag", false, "", true, 1500) == 0)
assert(decoder.decode_full("aag", false, "", true, 0)[1].text == "书")
assert(decoder.has_complete_candidate("gyygch", "羊"))
assert(not decoder.has_complete_candidate("gyygch", "错"))
assert(not decoder.has_complete_candidate("vuy", ""))
-- 空码顶屏的排除文本只忽略与该文本完全相同的完整路径
assert(decoder.has_complete_candidate("otw", ""))
assert(
    not decoder.has_complete_candidate("otw", "", true, 1500, "题", true, nil),
    "排除唯一候选后仍报告完整路径"
)
assert(
    decoder.has_complete_candidate("otw", "", true, 1500, "是", true, nil),
    "不同文本的完整路径被误排除"
)
local optimal_single = decoder.decode_full("u", false, "", true, 0)[1]
assert(optimal_single.text == "的")
assert(
    math.abs(
        optimal_single.score
            - optimal_single.confidence_score
            - config.whole_input_single_character_reward
    ) < 1e-12,
    "整码单字补偿污染置信度"
)
local baseline_cases = {
    gyygch = "羊羔",
    awmenamcunta = "买椟还珠",
    nuusvbbhoi = "左手匕首",
    iejryfenahbmsp = "新人上午来面试",
}
for raw, expected in pairs(baseline_cases) do
    assert(decoder.decode_full(raw)[1].text == expected, "基准候选回归：" .. raw)
end

-- 惰性切分串必须与字面量一致：候选互相比会在两边同时出错时漏判
assert(decoder.decode_full("xrxbj")[1].segmented == "xr xbj", "惰性切分串不符：xrxbj")
assert(
    decoder.decode_full("korylkugkugkskorkor")[1].segmented == "kor yl kug kug ks kor kor",
    "惰性切分串不符：korylkugkugkskorkor"
)
assert(decoder.decode_full("gyygch")[1].segmented == "gyy gch", "惰性切分串不符：gyygch")

-- 路径级孤立惩罚缓存必须与整串重算一致；漏传 edge_chars 或缓存失效会在这里暴露
local function assert_isolation_oracle(raw, include_early_commit, required_prefix, lock)
    local result = decoder.decode_full(raw, include_early_commit, required_prefix, true, 1500, lock)
    for index = 1, #result do
        local candidate = result[index]
        assert(
            decoder.path_isolation_penalty(candidate.path)
                == model.reference_isolation_penalty(candidate.text),
            "路径级孤立惩罚与整串重算不一致：" .. raw .. " 候选 " .. index
        )
    end
    for index = 1, #result.early_commit_candidates do
        local candidate = result.early_commit_candidates[index]
        assert(
            decoder.path_isolation_penalty(candidate.path)
                == model.reference_isolation_penalty(candidate.text),
            "尾码候选的孤立惩罚不一致：" .. raw .. " 候选 " .. index
        )
    end
end
for raw in pairs(baseline_cases) do
    assert_isolation_oracle(raw)
    assert_isolation_oracle(raw, true)
end
for _, raw in ipairs({
    "xrxbj;a",
    "korylkugkugkskorkor",
    "kormylkugkugkskorgkorg",
    "xrxbj",
    "gyygyygyyae",
    "awmenamcunta",
}) do
    assert_isolation_oracle(raw)
    assert_isolation_oracle(raw, true)
end

-- 缺少边字符的格网节点必须报错，而不是静默漏算惩罚
local orphan_item = { text = "甲", raw_length = 1, previous = { raw_length = 0 } }
local orphan_ok, orphan_error = pcall(decoder.path_isolation_penalty, orphan_item)
assert(
    not orphan_ok and tostring(orphan_error):find("缺少字符数组", 1, true),
    tostring(orphan_error)
)

-- 从无效选重尾码退回后，不能复用缺失有效路径的格网
for _, limit in ipairs({ 0, 1500 }) do
    for _, duplicate in ipairs({ false, true }) do
        decoder.reset()
        decoder.decode("xrxbj;a", false, "", duplicate, limit)
        local edited = decoder.decode("xrxbj", false, "", duplicate, limit)
        assert(#edited > 0, "退格后缺失有效候选")
        assert_equal(
            edited,
            decoder.decode_full("xrxbj", false, "", duplicate, limit),
            "选重尾码退格"
        )
    end
end

-- 长前缀退格覆盖字母、选重符和多位数字，并检查退格后的重新追加
for _, limit in ipairs({ 0, 1500 }) do
    for _, duplicate in ipairs({ false, true }) do
        for _, raw in ipairs({ "gyyxrxbj;a", "gyyxrxbj'a", "gyyxrxbj01230", "gyyxrxbja" }) do
            decoder.reset()
            decoder.decode(raw, true, "", duplicate, limit)
            for length = #raw - 1, 1, -1 do
                local prefix = raw:sub(1, length)
                assert_equal(
                    decoder.decode(prefix, true, "", duplicate, limit),
                    decoder.decode_full(prefix, true, "", duplicate, limit),
                    "选重边界退格：" .. prefix
                )
                assert_equal(
                    decoder.decode(prefix .. "a", true, "", duplicate, limit),
                    decoder.decode_full(prefix .. "a", true, "", duplicate, limit),
                    "退格后追加：" .. prefix
                )
                assert_equal(
                    decoder.decode(prefix, true, "", duplicate, limit),
                    decoder.decode_full(prefix, true, "", duplicate, limit),
                    "追加后恢复前缀：" .. prefix
                )
            end
        end
    end
end

-- 先竞争前 20 项，已提交文本只约束输出和自动提交证据
for _, case in ipairs({
    { "korylkugku", "汨罗" },
    { "korylkugkugkskorkor", "汨罗江" },
    { "awmenamcunta", "错" },
}) do
    assert_equal(
        decoder.decode_full(case[1], false, case[2]),
        decoder.decode_full(case[1]),
        "已提交前缀提前改变候选竞争：" .. case[1]
    )
end

decoder.reset()
for _, prefix in ipairs({ "", "买", "错", "买" }) do
    local result = decoder.decode("awmen", true, prefix)
    assert_equal(result, decoder.decode_full("awmen", true, prefix), "切换已提交前缀")
    for _, candidate in ipairs(result.early_commit_candidates) do
        assert(candidate.text:sub(1, #prefix) == prefix, "尾码证据混入不兼容前缀")
    end
    if prefix == "错" then
        assert(
            not result.early_commit_uses_incomplete_tail,
            "无兼容路径仍计入中性尾码代"
        )
        local prefixes = confidence.prefixes(result, prefix, 0.99999)
        assert(#prefixes == 0, "无兼容路径仍产生自动提交证据")
    end
end
assert_equal(
    decoder.decode("awmena", true, "买"),
    decoder.decode_full("awmena", true, "买"),
    "前缀约束下的增量追加"
)

decoder.reset()
decoder.decode("iejryfenahbmsp", false)
assert_equal(
    decoder.decode("iejryfenahbmsp", true),
    decoder.decode_full("iejryfenahbmsp", true),
    "相同输入缓存"
)

local wide = decoder.decode_full("aaaaaaaaaa", true)
assert(#wide == 20, "可见候选没有精确限制为 20 项")
local long_history = string.rep("gyy", 43)
assert(
    #decoder.decode_full(long_history) > 0,
    "已提交历史使完整解码超过 128 码时失效"
)
assert_equal(
    decoder.decode(long_history),
    decoder.decode_full(long_history),
    "长历史增量解码"
)
assert(#decoder.decode_full(string.rep("gyy", 42) .. "ae") > 0, "128 码有效输入不可解码")

math.randomseed(36491)
local alphabet = "abcdefghijklmnopqrstuvwxyz"
for case = 1, 100 do
    local length = math.random(1, 18)
    local parts = {}
    for index = 1, length do
        local at = math.random(#alphabet)
        parts[index] = alphabet:sub(at, at)
    end
    local raw = table.concat(parts)
    decoder.reset()
    for index = 1, #raw do
        local prefix = raw:sub(1, index)
        assert_equal(
            decoder.decode(prefix, true),
            decoder.decode_full(prefix, true),
            string.format("追加用例 %d，前缀 %d（%s）", case, index, prefix)
        )
    end
end

local edit_alphabet = "abcdefghijklmnopqrstuvwxyz;'0123456789"
math.randomseed(21977)
for case = 1, 100 do
    local length = math.random(2, 14)
    local parts = {}
    for index = 1, length do
        local at = math.random(#edit_alphabet)
        parts[index] = edit_alphabet:sub(at, at)
    end
    local raw = table.concat(parts)
    decoder.reset()
    decoder.decode(raw, true)
    for index = #raw - 1, 1, -1 do
        local prefix = raw:sub(1, index)
        assert_equal(
            decoder.decode(prefix, true),
            decoder.decode_full(prefix, true),
            string.format("退格用例 %d，前缀 %d（%s）", case, index, prefix)
        )
    end
end

-- 合法码段、选重和长输入覆盖 Beam 收缩及数字后缀扩展
local pieces = { "gyy", "gch", "jtgo;", "ae01", "aw", "enam", "cunta", "a;" }
math.randomseed(72631)
for _ = 1, 40 do
    local raw = ""
    for _ = 1, math.random(8, 12) do
        raw = raw .. pieces[math.random(#pieces)]
    end
    decoder.reset()
    for index = 1, #raw do
        local prefix = raw:sub(1, index)
        assert_equal(
            decoder.decode(prefix, true),
            decoder.decode_full(prefix, true),
            "合法追加：" .. prefix
        )
    end
    for index = #raw - 1, 1, -1 do
        local prefix = raw:sub(1, index)
        assert_equal(
            decoder.decode(prefix, true),
            decoder.decode_full(prefix, true),
            "合法退格：" .. prefix
        )
    end
end

local bucket = beam.new_bucket()
for index = 1, 201 do
    beam.add(bucket, {
        score = -index,
        mass_score = -index,
        text = tostring(index),
        prev2 = "甲",
        prev1 = "乙",
        max_rank = 1,
        supplement_state = 1,
        supplement_score = 0,
        previous = nil,
        text_length = #tostring(index),
        raw_length = 2,
        edge_count = 1,
    })
end
local first_limit = beam.limit(bucket, 200, beam.rank_first)
local second_limit = beam.limit(first_limit, 200, beam.rank_first)
assert(first_limit._truncated and second_limit._truncated, "Beam 截断事实未继承")
assert(first_limit == second_limit, "冻结 Beam 被重复复制")

math.randomseed(9182)
for _ = 1, 500 do
    local values = {}
    local candidate_bucket = beam.new_bucket()
    local count = math.random(1, 500)
    local limit = math.random(1, 250)
    for index = 1, count do
        local item = {
            score = math.random(),
            mass_score = 0,
            text = string.format("%04d", index),
            prev2 = "甲",
            prev1 = "乙",
            max_rank = math.random(1, 10),
            supplement_state = 1,
            supplement_score = 0,
            previous = nil,
            text_length = 4,
            raw_length = 2,
            edge_count = 1,
        }
        values[index] = item
        beam.add(candidate_bucket, item)
    end
    table.sort(values, beam.rank_first)
    local selected = beam.limit(candidate_bucket, limit, beam.rank_first)
    assert(#selected == math.min(count, limit), "Beam 前 k 项数量错误")
    for index = 1, #selected do
        assert(selected[index] == values[index], "Beam 前 k 项顺序错误")
    end
end

local function path(raw_length)
    local prefix = {
        score = 0,
        mass_score = 0,
        text = "甲乙",
        prev2 = "甲",
        prev1 = "乙",
        max_rank = 1,
        supplement_state = 1,
        supplement_score = 0,
        previous = nil,
        text_length = #"甲乙",
        raw_length = raw_length,
        edge_count = 1,
    }
    return {
        score = 0,
        mass_score = 0,
        text = "甲乙丙",
        prev2 = "乙",
        prev1 = "丙",
        max_rank = 1,
        supplement_state = 1,
        supplement_score = 0,
        previous = prefix,
        text_length = #"甲乙丙",
        raw_length = 5,
        edge_count = 2,
    }
end

local duplicate_bucket = beam.new_bucket()
local first_path = path(3)
local second_path = path(4)
beam.add(duplicate_bucket, first_path)
beam.add(duplicate_bucket, second_path)
local merged_paths = beam.limit(duplicate_bucket, 200, beam.rank_first)
assert(#merged_paths == 1, "相同文本没有聚合")
assert(math.abs(merged_paths[1].mass_score - math.log(2)) < 1e-12, "文本概率质量未合并")
assert(not merged_paths._truncated, "同文概率合并不应视为候选裁剪")
local same_bucket = beam.new_bucket()
beam.add(same_bucket, path(3))
beam.add(same_bucket, path(3))
assert(
    not beam.limit(same_bucket, 200, beam.rank_first)._truncated,
    "相同切分被误作边界信息丢失"
)
second_path.text = "甲乙丁"
second_path.prev1 = "丁"
local boundary_candidates = {
    { confidence_score = 0, text = first_path.text, path = first_path },
    { confidence_score = 0, text = second_path.text, path = second_path },
}
local prefix_evidence = confidence.prefixes(boundary_candidates, nil, 0.99999)
for _, prefix in ipairs(prefix_evidence) do
    if prefix.text == "甲乙" then
        assert(prefix.share == 0.5 and not prefix.boundary_closed, "异边界证据被错误封闭")
    end
end

decoder.reset()
model.close()

-- 高频过滤后若只剩非首选简词，不能把空候选数组当成可达的组句边
local lookup = lexicon.lookup
rawset(lexicon, "lookup", function(code)
    return code == "zz" and { { t = "词语", r = 2 } } or nil
end)
assert(not decoder.has_complete_candidate("zzzz"))
assert(#decoder.decode_full("zzzz") == 0)
assert(decoder.has_complete_candidate("zz", ""), "整段单边没有隐式显示非首选多字词")
assert(
    not decoder.has_complete_candidate("zz", "", true, 1500, nil, true, nil),
    "组句资格没有排除非首选多字词"
)
rawset(lexicon, "lookup", lookup)

-- 锁定候选只允许从锁定边界继续扩展，且不进入增量缓存
local function lock_of(raw, candidate)
    local boundaries, node = {}, candidate.path
    while node and node.raw_length > 0 do
        table.insert(boundaries, 1, node.raw_length .. "," .. node.text_length .. ";")
        node = node.previous
    end
    return {
        raw = raw:sub(1, candidate.path.raw_length),
        text = candidate.text,
        boundaries = table.concat(boundaries),
    }
end

local locked_raw = "korylkugkugkskorkor"
local unlocked = decoder.decode_full(locked_raw)
local lock = lock_of(locked_raw, unlocked[1])
local locked_result = decoder.decode_full(locked_raw, false, "", true, 1500, lock)
assert(#locked_result > 0, "锁定解码没有候选")
assert(locked_result[1].text == unlocked[1].text, "锁定解码首选不符")
for index = 1, #locked_result do
    assert(
        locked_result[index].text:sub(1, #lock.text) == lock.text,
        "锁定解码越过了锁定边界"
    )
    assert(
        decoder.path_isolation_penalty(locked_result[index].path)
            == model.reference_isolation_penalty(locked_result[index].text),
        "锁定路径的孤立惩罚与整串重算不一致"
    )
    assert(
        locked_result[index].segmented == unlocked[index].segmented,
        "锁定路径的切分串与完整解码不一致"
    )
end
local locked_extended = decoder.decode_full(locked_raw .. "gyygch", false, "", true, 1500, lock)
assert(
    #locked_extended > 0 and locked_extended[1].text:sub(1, #lock.text) == lock.text,
    "锁定后的追加解码不符"
)
assert(
    #decoder.decode_full("zzzz", false, "", true, 1500, lock) == 0,
    "锁定前缀不匹配仍产生候选"
)
assert(
    decoder.has_complete_candidate(locked_raw .. "gyygch", lock.text, true, 1500, nil, false, lock),
    "锁定完整候选遗漏"
)

decoder.reset()
assert_equal(
    decoder.decode(locked_raw),
    decoder.decode_full(locked_raw),
    "锁定解码前的缓存"
)
assert_equal(decoder.decode(locked_raw, false, "", true, 1500, lock), locked_result, "锁定解码")
assert_equal(
    decoder.decode(locked_raw),
    decoder.decode_full(locked_raw),
    "锁定解码污染了增量缓存"
)
