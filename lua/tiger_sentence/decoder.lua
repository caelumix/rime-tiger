-- 负责整句格网扩展、增量追加与候选输出
local beam = require("tiger_sentence.decoder.beam")
local config = require("tiger_sentence.config")
local lexicon = require("tiger_sentence.data.lexicon")
local model = require("tiger_sentence.model")
local supplement = require("tiger_sentence.decoder.supplement")
local text = require("tiger_sentence.text")

---@class TigerSentenceLock
---@field raw string
---@field text string
---@field boundaries string

---@class TigerSentenceDecodedCandidate
---@field score number
---@field confidence_score number
---@field text string
---@field segmented string|nil 惰性生成，读取时才计算
---@field _raw string|nil 生成切分串所需的原始编码
---@field max_rank integer
---@field supplement_score number
---@field path TigerSentenceBeamState
---@field edge_count integer

---@class TigerSentenceDecodeResult
---@field [integer] TigerSentenceDecodedCandidate
---@field confidence_truncated boolean
---@field early_commit_candidates TigerSentenceDecodedCandidate[]
---@field early_commit_confidence_truncated boolean
---@field early_commit_uses_incomplete_tail boolean

---@class TigerSentenceDecodeCache
---@field raw string|nil
---@field states TigerSentenceBeamBucket[]|nil
---@field result TigerSentenceDecodeResult|nil
---@field includes_early_commit boolean
---@field required_text_prefix string
---@field allow_duplicate_single boolean
---@field high_frequency_limit integer
---@field model_generation integer

local M = {}
local beam_width = config.beam_width
local candidate_limit = config.candidate_limit
local emitted_character_reward = config.emitted_character_reward
local rank_penalty = config.rank_penalty
local isolation_lambda = model.isolation_lambda
local logp = model.logp
local utf8_chars = text.chars
local add_state = beam.add
local limit_states = beam.limit
local new_bucket = beam.new_bucket
local select_candidates = beam.select
local rank_first = beam.rank_first
local score_first = beam.score_first
local no_model = beam.no_model
local supplement_matcher = supplement.load_default()
local has_supplements = supplement_matcher.count > 0
local rank_logs = {}

local function state_comparator(allow_duplicate_single)
    if not model.available() then
        return no_model
    end
    return allow_duplicate_single and score_first or rank_first
end

---@type TigerSentenceDecodeCache
local cache = {
    raw = nil,
    states = nil,
    result = nil,
    includes_early_commit = false,
    required_text_prefix = "",
    allow_duplicate_single = true,
    high_frequency_limit = config.high_frequency_limit,
    model_generation = model.generation,
}
local max_code_length = 1

for index = 1, #lexicon.lengths do
    max_code_length = math.max(max_code_length, lexicon.lengths[index])
end

local function trailing_selector_span(raw)
    local index = #raw
    while index >= 1 do
        local mark = raw:sub(index, index)
        if mark:match("%d") or mark == ";" or mark == "'" then
            index = index - 1
        else
            break
        end
    end
    return #raw - index
end

local function candidate_chars(candidate)
    if not candidate._chars then
        candidate._chars = utf8_chars(candidate.t)
    end
    return candidate._chars
end

local function rank_log(rank)
    local cached = rank_logs[rank]
    if cached == nil then
        cached = math.log(rank)
        rank_logs[rank] = cached
    end
    return cached
end

local function eligible_candidates(
    candidates,
    selected_rank,
    whole_input_edge,
    allow_duplicate_single
)
    if selected_rank == 0 and whole_input_edge then
        return candidates
    end
    if selected_rank == 0 then
        if allow_duplicate_single then
            if candidates._duplicate then
                return candidates._duplicate
            end
            local selected = {}
            for index = 1, #candidates do
                local candidate = candidates[index]
                if candidate.r == 1 or #candidate_chars(candidate) == 1 then
                    selected[#selected + 1] = candidate
                end
            end
            candidates._duplicate = selected
            return selected
        end
    end

    local rank = selected_rank > 0 and selected_rank or 1
    local cache_key = "_rank_" .. tostring(rank)
    if candidates[cache_key] then
        return candidates[cache_key]
    end
    local selected = {}
    for index = 1, #candidates do
        local candidate = candidates[index]
        if candidate.r == rank then
            selected[#selected + 1] = candidate
        end
    end
    if #selected == 0 then
        return nil
    end
    candidates[cache_key] = selected
    return selected
end

local function advance_required_prefix(required, matched_length, candidate_text)
    if matched_length >= #required then
        return matched_length
    end
    local compare_length = math.min(#candidate_text, #required - matched_length)
    if
        required:sub(matched_length + 1, matched_length + compare_length)
        ~= candidate_text:sub(1, compare_length)
    then
        return nil
    end
    return math.min(#required, matched_length + #candidate_text)
end

local function parse_selector(raw, code_end)
    local next_index = code_end + 1
    if next_index > #raw then
        return 0, code_end
    end
    local mark = raw:sub(next_index, next_index)
    if mark == ";" then
        return 2, next_index
    end
    if mark == "'" then
        return 3, next_index
    end
    if not mark:match("%d") then
        return 0, code_end
    end

    local digit_end = next_index
    while digit_end < #raw and raw:sub(digit_end + 1, digit_end + 1):match("%d") do
        digit_end = digit_end + 1
    end
    local token = raw:sub(next_index, digit_end)
    if token == "0" then
        return 10, digit_end
    end
    return tonumber(token), digit_end
end

local function new_states(length)
    local states = {}
    for position = 0, length do
        states[position] = new_bucket()
    end
    add_state(states[0], {
        score = 0,
        mass_score = 0,
        text = "",
        prev2 = model.BOS,
        prev1 = model.BOS,
        max_rank = 1,
        supplement_state = 1,
        supplement_score = 0,
        previous = nil,
        text_length = 0,
        raw_length = 0,
        edge_count = 0,
    })
    return states
end

-- 不分配边对象，直接解析一条格网边，减少按键热路径中的临时对象
local function resolve_edge(
    raw,
    position,
    code_length,
    input_length,
    minimum_end,
    allow_duplicate_single,
    high_frequency_limit
)
    local code_end = position + code_length
    if code_end > input_length then
        return nil
    end
    local candidates = lexicon.lookup(raw:sub(position + 1, code_end), high_frequency_limit)
    if not candidates then
        return nil
    end
    local selected_rank, consumed_end = parse_selector(raw, code_end)
    if consumed_end <= minimum_end or (input_length > 1 and consumed_end - position < 2) then
        return nil
    end
    local whole_input_edge = position == 0 and consumed_end == input_length
    local selected =
        eligible_candidates(candidates, selected_rank, whole_input_edge, allow_duplicate_single)
    if not selected or #selected == 0 then
        return nil
    end
    return selected, selected_rank, consumed_end, whole_input_edge
end

-- 每条有效词典边只扩展一次
local function expand_edge(states, current, selected, selected_rank, consumed_end, whole_input_edge)
    local target = states[consumed_end]
    for state_index = 1, #current do
        local item = current[state_index]
        for candidate_index = 1, #selected do
            local candidate = selected[candidate_index]
            local score = item.score
            local previous2 = item.prev2
            local previous1 = item.prev1
            local supplement_state = item.supplement_state
            local supplement_added = 0
            local characters = candidate_chars(candidate)
            for character_index = 1, #characters do
                score = score + logp(previous2, previous1, characters[character_index])
                score = score + emitted_character_reward
                if has_supplements then
                    local reward
                    supplement_state, reward = supplement.advance(
                        supplement_matcher,
                        supplement_state,
                        characters[character_index]
                    )
                    score = score + reward
                    supplement_added = supplement_added + reward
                end
                previous2 = previous1
                previous1 = characters[character_index]
            end
            if selected_rank == 0 and candidate.r > 1 then
                score = score - rank_penalty * rank_log(candidate.r)
            end
            local whole_input_reward = 0
            if whole_input_edge and selected_rank == 0 and candidate.o and #characters == 1 then
                whole_input_reward = config.whole_input_single_character_reward
                score = score + whole_input_reward
            end
            local value = item.text .. candidate.t
            add_state(target, {
                edge_chars = characters,
                score = score,
                mass_score = item.mass_score
                    + score
                    - item.score
                    - supplement_added
                    - whole_input_reward,
                text = value,
                prev2 = previous2,
                prev1 = previous1,
                max_rank = math.max(item.max_rank, candidate.r),
                supplement_state = supplement_state,
                supplement_score = item.supplement_score + supplement_added,
                previous = item,
                text_length = #value,
                raw_length = consumed_end,
                edge_count = item.edge_count + 1,
            })
        end
    end
end

local function beam_limit_at(position)
    return position > config.long_input_full_beam_length and config.long_input_beam_width
        or beam_width
end

local function expand_range(
    raw,
    states,
    from_position,
    length,
    minimum_end,
    allow_duplicate_single,
    high_frequency_limit
)
    local required_end = minimum_end or -1
    local better = state_comparator(allow_duplicate_single)
    for position = from_position, length - 1 do
        local current = limit_states(states[position], beam_limit_at(position), better)
        states[position] = current
        if #current > 0 then
            for index = 1, #lexicon.lengths do
                local selected, selected_rank, consumed_end, whole_input_edge = resolve_edge(
                    raw,
                    position,
                    lexicon.lengths[index],
                    length,
                    required_end,
                    allow_duplicate_single,
                    high_frequency_limit
                )
                if selected then
                    expand_edge(
                        states,
                        current,
                        selected,
                        selected_rank,
                        consumed_end,
                        whole_input_edge
                    )
                end
            end
        end
    end
end

local function segmented_from_path(raw, path)
    local ends = {}
    while path and path.raw_length > 0 do
        ends[#ends + 1] = path.raw_length
        path = path.previous
    end
    local pieces = {}
    local start = 1
    for index = #ends, 1, -1 do
        local finish = ends[index]
        pieces[#pieces + 1] = raw:sub(start, finish)
        start = finish + 1
    end
    return table.concat(pieces, " ")
end

-- 孤立惩罚按路径增量累计并缓存在格网节点上，避免每次追加重算整句
local function path_isolation_penalty(item)
    if not item or not model.isolation_enabled() then
        return 0
    end
    if item._isolation_penalty ~= nil then
        return item._isolation_penalty
    end
    local characters = item.edge_chars
    if characters == nil then
        -- 只有起始种子没有边字符；其余节点漏传必须立即暴露
        assert(item.previous == nil, "格网边缺少字符数组")
        return 0
    end
    local previous = item.previous
    local penalty = path_isolation_penalty(previous)
    local last_char = previous and previous._isolation_last_char
    local last_isolated = previous and previous._isolation_last_isolated or false
    for index = 1, #characters do
        local character = characters[index]
        local rare = model.is_rare_character(character)
        local linked = last_char
            and (last_isolated or rare)
            and model.observed_bigram(last_char, character)
        -- 上一个字符曾被判为孤立，但右邻现在成词，撤销先前累计的惩罚
        if last_isolated and linked then
            penalty = penalty - isolation_lambda
        end
        last_isolated = rare and not linked
        if last_isolated then
            penalty = penalty + isolation_lambda
        end
        last_char = character
    end
    item._isolation_penalty = penalty
    item._isolation_last_char = last_char
    item._isolation_last_isolated = last_isolated
    return penalty
end

-- 切分串只在取用时生成，避免每次按键为全部候选分配字符串
local candidate_display_meta = {
    __index = function(candidate, key)
        if key ~= "segmented" then
            return nil
        end
        local value = segmented_from_path(candidate._raw, candidate.path)
        rawset(candidate, key, value)
        return value
    end,
}

local function decoded_candidate(item)
    -- 固定浮点加减的结合顺序，避免接近同分的候选换位
    local ending = logp(item.prev2, item.prev1, model.EOS) - path_isolation_penalty(item)
    local candidate = {
        score = item.score + ending,
        confidence_score = item.mass_score + ending,
        text = item.text,
        max_rank = item.max_rank,
        supplement_score = item.supplement_score,
        path = item,
        edge_count = item.edge_count,
    }
    return candidate
end

local function logsumexp(left, right)
    local maximum = math.max(left, right)
    return maximum + math.log(math.exp(left - maximum) + math.exp(right - maximum))
end

local function add_early_commit_states(values, mass_by_key, best_by_key, required_prefix)
    local added = false
    for index = 1, #values do
        local value = values[index]
        local candidate = value.confidence_score and value or decoded_candidate(value)
        if candidate.text ~= "" and candidate.text:sub(1, #required_prefix) == required_prefix then
            added = true
            local key = candidate.text .. "\0" .. candidate.path.raw_length
            local previous_mass = mass_by_key[key]
            mass_by_key[key] = previous_mass
                    and logsumexp(previous_mass, candidate.confidence_score)
                or candidate.confidence_score
            local previous = best_by_key[key]
            if not previous or candidate.confidence_score > previous.confidence_score then
                best_by_key[key] = candidate
            end
        end
    end
    return added
end

local function incomplete_code_tail(tail, high_frequency_limit)
    return tail:match("^[a-z]+$") ~= nil
        and lexicon.has_proper_prefix(tail, high_frequency_limit)
        and (#tail < 2 or not lexicon.lookup(tail, high_frequency_limit))
end

-- 合法但未完成的尾码仅参与提前上屏置信度，不进入可见候选
local function early_commit_candidates(
    raw,
    states,
    completed,
    completed_truncated,
    allow_duplicate_single,
    high_frequency_limit,
    required_prefix
)
    if completed_truncated then
        return {}, true, false
    end
    local mass_by_key = {}
    local best_by_key = {}
    local truncated = completed_truncated or false
    local uses_incomplete_tail = false
    add_early_commit_states(completed, mass_by_key, best_by_key, required_prefix)

    local maximum_tail = math.min(max_code_length - 1, #raw - 1)
    for tail_length = 1, maximum_tail do
        local consumed = #raw - tail_length
        local tail = raw:sub(consumed + 1)
        if incomplete_code_tail(tail, high_frequency_limit) then
            local better = state_comparator(allow_duplicate_single)
            local partial = limit_states(states[consumed], beam_limit_at(consumed), better)
            states[consumed] = partial
            if add_early_commit_states(partial, mass_by_key, best_by_key, required_prefix) then
                uses_incomplete_tail = true
                truncated = truncated or (partial._truncated or false)
            end
        end
    end
    if not uses_incomplete_tail then
        return {}, false, false
    end

    local result = {}
    for key, candidate in pairs(best_by_key) do
        result[#result + 1] = {
            score = candidate.score,
            confidence_score = mass_by_key[key],
            text = candidate.text,
            max_rank = candidate.max_rank,
            supplement_score = candidate.supplement_score,
            path = candidate.path,
        }
    end
    table.sort(result, function(left, right)
        if left.confidence_score == right.confidence_score then
            return left.text < right.text
        end
        return left.confidence_score > right.confidence_score
    end)
    return result, truncated, true
end

local function emit(
    raw,
    states,
    length,
    include_early_commit,
    allow_duplicate_single,
    high_frequency_limit,
    required_prefix
)
    local better = state_comparator(allow_duplicate_single)
    local completed = limit_states(states[length], beam_limit_at(length), better)
    states[length] = completed
    ---@type TigerSentenceDecodedCandidate[]
    local all_candidates = {}
    for index = 1, #completed do
        all_candidates[index] = decoded_candidate(completed[index])
    end
    local result
    local has_model = model.available()
    local output_better = has_model and rank_first or no_model
    if has_model and allow_duplicate_single then
        for _, candidate in ipairs(all_candidates) do
            local previous = candidate.path.previous
            if previous and previous.raw_length > 0 then
                output_better = score_first
                break
            end
        end
    end
    if #all_candidates > candidate_limit then
        result = select_candidates(all_candidates, candidate_limit, output_better)
    else
        table.sort(all_candidates, output_better)
        result = all_candidates
    end
    ---@cast result TigerSentenceDecodedCandidate[]
    for index = 1, #result do
        result[index]._raw = raw
        setmetatable(result[index], candidate_display_meta)
    end
    ---@cast result TigerSentenceDecodeResult
    result.confidence_truncated = completed._truncated or false
    result.early_commit_candidates = {}
    result.early_commit_confidence_truncated = false
    result.early_commit_uses_incomplete_tail = false
    if include_early_commit then
        local candidates, truncated, uses_incomplete_tail = early_commit_candidates(
            raw,
            states,
            result,
            completed._truncated,
            allow_duplicate_single,
            high_frequency_limit,
            required_prefix
        )
        result.early_commit_candidates = candidates
        result.early_commit_confidence_truncated = truncated
        result.early_commit_uses_incomplete_tail = uses_incomplete_tail
    end
    return result
end

---@return TigerSentenceDecodeResult
local function empty_result()
    return {
        confidence_truncated = false,
        early_commit_candidates = {},
        early_commit_confidence_truncated = false,
        early_commit_uses_incomplete_tail = false,
    }
end

-- 锁定候选：按已确认边界重建种子路径，新边不跨越锁定处
local function decode_locked(
    raw,
    locked,
    include_early_commit,
    required_text_prefix,
    allow_duplicate_single,
    high_frequency_limit
)
    local prefix = text.normalize(locked.raw)
    if prefix == "" or raw:sub(1, #prefix) ~= prefix then
        return nil
    end
    local seed = {
        text = "",
        prev2 = model.BOS,
        prev1 = model.BOS,
        score = 0,
        mass_score = 0,
        max_rank = 1,
        supplement_state = 1,
        supplement_score = 0,
        raw_length = 0,
        text_length = 0,
        edge_count = 0,
    }
    for raw_boundary, text_boundary in locked.boundaries:gmatch("(%d+),(%d+);") do
        local raw_length = tonumber(raw_boundary)
        local text_length = tonumber(text_boundary)
        local characters = utf8_chars(locked.text:sub(seed.text_length + 1, text_length))
        local item = {
            text = locked.text:sub(1, text_length),
            previous = seed,
            edge_chars = characters,
            raw_length = raw_length,
            text_length = text_length,
            edge_count = seed.edge_count + 1,
            prev2 = seed.prev2,
            prev1 = seed.prev1,
            score = seed.score,
            supplement_state = seed.supplement_state,
            supplement_score = seed.supplement_score,
            max_rank = 1,
        }
        for _, character in ipairs(characters) do
            item.score = item.score
                + logp(item.prev2, item.prev1, character)
                + emitted_character_reward
            if has_supplements then
                local reward
                item.supplement_state, reward =
                    supplement.advance(supplement_matcher, item.supplement_state, character)
                item.score = item.score + reward
                item.supplement_score = item.supplement_score + reward
            end
            item.prev2, item.prev1 = item.prev1, character
        end
        item.mass_score = item.score - item.supplement_score
        seed = item
    end
    if seed.raw_length ~= #prefix or seed.text ~= locked.text then
        return nil
    end
    -- 种子取代 BOS 种子后的格网只从锁定末端扩展
    local states = new_states(#raw)
    states[0] = new_bucket()
    add_state(states[#prefix], seed)
    expand_range(raw, states, #prefix, #raw, nil, allow_duplicate_single, high_frequency_limit)
    return emit(
        raw,
        states,
        #raw,
        include_early_commit or false,
        allow_duplicate_single,
        high_frequency_limit,
        required_text_prefix
    )
end

local function reuse_cached_states(raw, allow_duplicate_single, high_frequency_limit)
    local old_raw = cache.raw
    local states = cache.states
    if not states or not old_raw or old_raw == "" then
        return nil
    end
    if
        cache.allow_duplicate_single ~= allow_duplicate_single
        or cache.high_frequency_limit ~= high_frequency_limit
        or cache.model_generation ~= model.generation
    then
        return nil
    end
    if raw == old_raw then
        return states
    end

    local length = #raw
    local old_length = #old_raw
    if length > max_code_length and length < old_length and old_raw:sub(1, length) == raw then
        for position = length + 1, old_length do
            states[position] = nil
        end
        -- 退掉选重符或截短数字名次时，只有新末端的词典边改变
        if old_raw:sub(length + 1, length + 1):match("[;'0-9]") then
            states[length] = new_bucket()
            local from_position =
                math.max(0, length - max_code_length - trailing_selector_span(raw))
            expand_range(
                raw,
                states,
                from_position,
                length,
                length - 1,
                allow_duplicate_single,
                high_frequency_limit
            )
        end
        return states
    end
    if
        old_length <= max_code_length
        or length <= old_length
        or raw:sub(1, old_length) ~= old_raw
    then
        return nil
    end

    local max_consume = max_code_length + trailing_selector_span(raw)
    local from_position = math.max(0, old_length + 1 - max_consume)
    for position = old_length + 1, length do
        states[position] = new_bucket()
    end
    expand_range(
        raw,
        states,
        from_position,
        length,
        old_length,
        allow_duplicate_single,
        high_frequency_limit
    )
    return states
end

-- 排除文本用于只统计“不是该候选”的完整路径，组句资格用于只统计合法组句边
---@param excluded_text string|nil
---@param group_eligible_only boolean|nil
---@param locked TigerSentenceLock|nil
function M.has_complete_candidate(
    raw_code,
    required_text_prefix,
    allow_duplicate_single,
    high_frequency_limit,
    excluded_text,
    group_eligible_only,
    locked
)
    local raw = text.normalize(raw_code)
    local required = required_text_prefix or ""
    allow_duplicate_single = allow_duplicate_single ~= false
    high_frequency_limit = high_frequency_limit or config.high_frequency_limit
    if raw == "" or not text.has_letter(raw) then
        return false
    end
    if required == "" and not excluded_text and not group_eligible_only and not locked then
        local reachable = { [0] = true }
        for position = 0, #raw - 1 do
            if reachable[position] then
                for _, code_length in ipairs(lexicon.lengths) do
                    local selected, _, consumed_end = resolve_edge(
                        raw,
                        position,
                        code_length,
                        #raw,
                        -1,
                        allow_duplicate_single,
                        high_frequency_limit
                    )
                    if selected and consumed_end then
                        reachable[consumed_end] = true
                    end
                end
            end
        end
        return reachable[#raw] or false
    end

    local first_ranks_only = group_eligible_only and not raw:find("[;'0-9]")
    local stride = excluded_text and (#excluded_text + 2) or 1
    local states = {}
    for position = 0, #raw do
        states[position] = {}
    end
    local start, matched, excluded = 0, 0, 0
    if locked then
        local prefix = text.normalize(locked.raw)
        matched = math.min(#required, #locked.text)
        if
            raw:sub(1, #prefix) ~= prefix
            or required:sub(1, matched) ~= locked.text:sub(1, matched)
        then
            return false
        end
        start = #prefix
        if excluded_text then
            excluded = excluded_text:sub(1, #locked.text) == locked.text and #locked.text
                or #excluded_text + 1
        end
        if start == #raw then
            return matched == #required and (not excluded_text or excluded ~= #excluded_text)
        end
    end
    -- 把一条可用边推进到目标位置；命中完整路径时返回 true
    local function advance(current, selected, consumed_end)
        local target = states[consumed_end]
        for packed in pairs(current) do
            local matched_length = math.floor(packed / stride)
            for _, candidate in ipairs(selected) do
                if
                    not first_ranks_only
                    or candidate.r == 1
                    or (allow_duplicate_single and #candidate_chars(candidate) == 1)
                then
                    local next_matched =
                        advance_required_prefix(required, matched_length, candidate.t)
                    if next_matched then
                        local next_excluded = packed % stride
                        if excluded_text and next_excluded < #excluded_text then
                            next_excluded = excluded_text:sub(
                                next_excluded + 1,
                                next_excluded + #candidate.t
                            ) == candidate.t and next_excluded + #candidate.t or #excluded_text + 1
                        end
                        if
                            consumed_end == #raw
                            and next_matched == #required
                            and (not excluded_text or next_excluded ~= #excluded_text)
                        then
                            return true
                        end
                        target[next_matched * stride + next_excluded] = true
                    end
                end
            end
        end
        return false
    end

    states[start][matched * stride + excluded] = true
    for position = start, #raw - 1 do
        local current = states[position]
        if next(current) then
            for _, code_length in ipairs(lexicon.lengths) do
                local selected, _, consumed_end = resolve_edge(
                    raw,
                    position,
                    code_length,
                    #raw,
                    -1,
                    allow_duplicate_single,
                    high_frequency_limit
                )
                if selected and advance(current, selected, consumed_end) then
                    return true
                end
            end
        end
    end
    return false
end

---@param raw_code string
---@param locked TigerSentenceLock|nil
---@return TigerSentenceDecodeResult
function M.decode_full(
    raw_code,
    include_early_commit,
    required_text_prefix,
    allow_duplicate_single,
    high_frequency_limit,
    locked
)
    local raw = text.normalize(raw_code)
    required_text_prefix = required_text_prefix or ""
    allow_duplicate_single = allow_duplicate_single ~= false
    high_frequency_limit = high_frequency_limit or config.high_frequency_limit
    if locked then
        return decode_locked(
            raw,
            locked,
            include_early_commit,
            required_text_prefix,
            allow_duplicate_single,
            high_frequency_limit
        ) or empty_result()
    end
    if raw == "" or not text.has_letter(raw) then
        return empty_result()
    end
    local states = new_states(#raw)
    expand_range(raw, states, 0, #raw, nil, allow_duplicate_single, high_frequency_limit)
    return emit(
        raw,
        states,
        #raw,
        include_early_commit or false,
        allow_duplicate_single,
        high_frequency_limit,
        required_text_prefix
    )
end

---@param raw_code string
---@param locked TigerSentenceLock|nil
---@return TigerSentenceDecodeResult
function M.decode(
    raw_code,
    include_early_commit,
    required_text_prefix,
    allow_duplicate_single,
    high_frequency_limit,
    locked
)
    local raw = text.normalize(raw_code)
    required_text_prefix = required_text_prefix or ""
    allow_duplicate_single = allow_duplicate_single ~= false
    high_frequency_limit = high_frequency_limit or config.high_frequency_limit
    -- 锁定路径不进入增量缓存：锁定改变可用边，缓存只能描述无锁格网
    if locked then
        return decode_locked(
            raw,
            locked,
            include_early_commit,
            required_text_prefix,
            allow_duplicate_single,
            high_frequency_limit
        ) or empty_result()
    end
    if raw == "" or not text.has_letter(raw) then
        cache = {
            raw = raw,
            states = nil,
            result = empty_result(),
            includes_early_commit = include_early_commit or false,
            required_text_prefix = required_text_prefix,
            allow_duplicate_single = allow_duplicate_single,
            high_frequency_limit = high_frequency_limit,
            model_generation = model.generation,
        }
        return cache.result
    end
    if
        cache.raw == raw
        and cache.result
        and cache.required_text_prefix == required_text_prefix
        and cache.allow_duplicate_single == allow_duplicate_single
        and cache.high_frequency_limit == high_frequency_limit
        and cache.model_generation == model.generation
        and (not include_early_commit or cache.includes_early_commit)
    then
        return cache.result
    end

    local states = reuse_cached_states(raw, allow_duplicate_single, high_frequency_limit)
    if not states then
        states = new_states(#raw)
        expand_range(raw, states, 0, #raw, nil, allow_duplicate_single, high_frequency_limit)
    end

    local result = emit(
        raw,
        states,
        #raw,
        include_early_commit or false,
        allow_duplicate_single,
        high_frequency_limit,
        required_text_prefix
    )
    cache = {
        raw = raw,
        states = states,
        result = result,
        includes_early_commit = include_early_commit or false,
        required_text_prefix = required_text_prefix,
        allow_duplicate_single = allow_duplicate_single,
        high_frequency_limit = high_frequency_limit,
        model_generation = model.generation,
    }
    return result
end

-- 独立 oracle：整串重算与路径级缓存必须给出同一惩罚
---@param item TigerSentenceBeamState
---@return number
function M.path_isolation_penalty(item)
    return path_isolation_penalty(item)
end

function M.reset()
    cache = {
        raw = nil,
        states = nil,
        result = nil,
        includes_early_commit = false,
        required_text_prefix = "",
        allow_duplicate_single = true,
        high_frequency_limit = config.high_frequency_limit,
        model_generation = model.generation,
    }
end

return M
