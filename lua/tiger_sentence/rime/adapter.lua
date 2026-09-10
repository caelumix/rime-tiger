-- 对接 Rime 的按键处理、候选输出与自动上屏
local confidence = require("tiger_sentence.decoder.confidence")
local config = require("tiger_sentence.config")
local decoder = require("tiger_sentence.decoder")
local lexicon = require("tiger_sentence.data.lexicon")
local state_store = require("tiger_sentence.rime.state")
local text = require("tiger_sentence.text")

local M = {}
local navigation_keys = { Down = true, Page_Down = true, Page_Up = true, Up = true }
local tracker_separator = "\31"

local function configured_integer(env, name, default)
    local value = env.engine.schema.config:get_int(name)
    if value == nil then
        return default
    end
    return math.max(0, math.floor(value))
end

local function decode_policy(env)
    local context = env.engine.context
    return {
        allow_duplicate = context:get_option("tiger_sentence_allow_duplicate_single"),
        high_frequency_limit = configured_integer(
            env,
            "tiger_sentence/high_freq_limit",
            config.high_frequency_limit
        ),
    }
end

local function active_raw(state, live_raw)
    return state.committed_raw .. live_raw
end

local function reset_evidence(state)
    state.trackers = {}
    state.last_seen_raw = ""
end

local function reset_session(env)
    state_store.reset(env)
    decoder.reset()
end

local function replace_input(context, value)
    context.input = value
    assert(context.input == value, "Rime 拒绝替换组合输入")
end

local function ends_with_digit(value)
    local characters = text.chars(value)
    local last = characters[#characters]
    return last and (last:match("^[0-9]$") or last:match("^\239\188[\144-\153]$")) ~= nil
end

local function commit_prefix(env, state, committed_text, raw_length, full_raw)
    local previous = {
        committed_text = state.committed_text,
        committed_raw = state.committed_raw,
        trackers = state.trackers,
        last_seen_raw = state.last_seen_raw,
        last_auto_commit_raw_length = state.last_auto_commit_raw_length,
        empty_code_pending = state.empty_code_pending,
        dot_armed = state.dot_armed,
    }
    local commit = committed_text:sub(#state.committed_text + 1)
    state.committed_text = committed_text
    state.committed_raw = full_raw:sub(1, raw_length)
    state.last_auto_commit_raw_length = raw_length
    state.empty_code_pending = nil
    reset_evidence(state)
    decoder.reset()
    local rebuilt, rebuild_error =
        pcall(replace_input, env.engine.context, full_raw:sub(raw_length + 1))
    if not rebuilt then
        for key, value in pairs(previous) do
            state[key] = value
        end
        error(rebuild_error, 0)
    end
    env.engine:commit_text(commit)
    if ends_with_digit(commit) then
        state.dot_armed = true
    end
    return true
end

local function prefix_extends(left, right)
    return left:sub(1, #right) == right or right:sub(1, #left) == left
end

local function find_prefix(prefixes, wanted)
    for _, prefix in ipairs(prefixes) do
        if prefix.text == wanted.text and prefix.raw_length == wanted.raw_length then
            return prefix
        end
    end
end

local function contradicted(tracker, prefixes)
    local own = find_prefix(prefixes, tracker)
    local own_share = own and own.share or 0
    for _, prefix in ipairs(prefixes) do
        if prefix.text ~= tracker.text and not prefix_extends(prefix.text, tracker.text) then
            local common = text.common_prefix(prefix.text, tracker.text)
            if
                common ~= ""
                and #common < #tracker.text
                and (not own or prefix.share > own_share)
            then
                return true
            end
        end
    end
    return false
end

local function candidate_has_boundary(candidate, prefix)
    if candidate.text:sub(1, #prefix.text) ~= prefix.text then
        return false
    end
    local path = candidate.path
    while path do
        if path.raw_length == prefix.raw_length and path.text_length == #prefix.text then
            return true
        end
        path = path.previous
    end
    return false
end

local function prefix_is_visible(prefix, candidates)
    for _, candidate in ipairs(candidates) do
        if candidate_has_boundary(candidate, prefix) then
            return true
        end
    end
    return false
end

local function retain_trackers(state, prefixes)
    local retained = {}
    for key, tracker in pairs(state.trackers) do
        local current = find_prefix(prefixes, tracker)
        if current and not contradicted(tracker, prefixes) then
            tracker.gap_count = tracker.gap_count + 1
            if tracker.gap_count <= config.early_commit_maximum_neutral_gap then
                tracker.last_share = current.share
                retained[key] = tracker
            end
        end
    end
    state.trackers = retained
end

local function tracker_better(left, right)
    if left.text_length ~= right.text_length then
        return left.text_length > right.text_length
    end
    if left.last_share ~= right.last_share then
        return left.last_share > right.last_share
    end
    return left.raw_length < right.raw_length
end

local function commit_mature_tracker(env, state, full_raw)
    local minimum = configured_integer(
        env,
        "tiger_sentence/min_retained_raw_length",
        config.early_commit_retained_raw_length
    )
    local retained = math.max(config.early_commit_retained_raw_length, minimum)
    local selected
    for _, tracker in pairs(state.trackers) do
        if
            (
                tracker.evidence_count >= config.early_commit_generations
                or tracker.strong_count >= config.early_commit_strong_generations
            )
            and tracker.raw_length > #state.committed_raw
            and #full_raw - tracker.raw_length >= retained
            and tracker.text:sub(1, #state.committed_text) == state.committed_text
            and (not selected or tracker_better(tracker, selected))
        then
            selected = tracker
        end
    end
    if
        not selected
        or #full_raw - state.last_auto_commit_raw_length
            < config.early_commit_retained_raw_length
    then
        return false
    end
    return commit_prefix(env, state, selected.text, selected.raw_length, full_raw)
end

local function try_early_commit(env, state, live_raw, policy)
    local context = env.engine.context
    local full_raw = active_raw(state, live_raw)
    if
        not context:get_option("tiger_sentence_early_commit")
        or state.suspended
        or #full_raw <= 4
    then
        reset_evidence(state)
        return false
    end

    local decoded = decoder.decode(
        full_raw,
        true,
        state.committed_text,
        policy.allow_duplicate,
        policy.high_frequency_limit
    )
    local candidates = decoded
    if decoded.early_commit_uses_incomplete_tail then
        candidates = decoded.early_commit_candidates
    end
    if
        decoded.confidence_truncated
        or decoded.early_commit_confidence_truncated
        or #candidates == 0
    then
        reset_evidence(state)
        return false
    end
    local prefixes, top_share = confidence.prefixes(
        candidates,
        state.committed_text,
        config.early_commit_closed_boundary_threshold
    )
    if state.last_seen_raw == full_raw then
        return commit_mature_tracker(env, state, full_raw)
    end
    if
        state.last_seen_raw ~= ""
        and (
            #full_raw ~= #state.last_seen_raw + 1
            or full_raw:sub(1, #state.last_seen_raw) ~= state.last_seen_raw
        )
    then
        state.trackers = {}
    end
    state.last_seen_raw = full_raw

    local accepted_top = decoded[1] and decoded[1].supplement_score > 0 and decoded[1].text or nil
    local qualifying = {}
    for _, prefix in ipairs(prefixes) do
        if
            prefix.boundary_closed
            and prefix.share >= config.confidence_threshold
            and prefix.raw_length > #state.committed_raw
            and #prefix.text > #state.committed_text
            and prefix.text:sub(1, #state.committed_text) == state.committed_text
            and (not accepted_top or accepted_top:sub(1, #prefix.text) == prefix.text)
            and (decoded.early_commit_uses_incomplete_tail or prefix_is_visible(prefix, decoded))
        then
            qualifying[prefix.text .. tracker_separator .. prefix.raw_length] = prefix
        end
    end

    if
        next(qualifying) == nil
        and (top_share < config.confidence_threshold or decoded.early_commit_uses_incomplete_tail)
    then
        retain_trackers(state, prefixes)
        return commit_mature_tracker(env, state, full_raw)
    end

    local trackers = {}
    for key, prefix in pairs(qualifying) do
        local tracker = state.trackers[key]
            or {
                text = prefix.text,
                text_length = text.length(prefix.text),
                raw_length = prefix.raw_length,
                evidence_count = 0,
                strong_count = 0,
                gap_count = 0,
                last_share = 0,
            }
        tracker.evidence_count =
            math.min(config.early_commit_generations, tracker.evidence_count + 1)
        tracker.strong_count = prefix.share >= config.early_commit_strong_threshold
                and math.min(config.early_commit_strong_generations, tracker.strong_count + 1)
            or 0
        tracker.gap_count = 0
        tracker.last_share = prefix.share
        trackers[key] = tracker
    end
    state.trackers = trackers
    return commit_mature_tracker(env, state, full_raw)
end

local function has_selection_suffix(raw)
    return raw:find("[;'0-9]") ~= nil
end

local function capture_empty_code_candidate(state, full_raw, policy)
    local decoded = decoder.decode(
        full_raw,
        true,
        state.committed_text,
        policy.allow_duplicate,
        policy.high_frequency_limit
    )
    if #decoded == 0 then
        return nil
    end
    local eligible = {}
    local unrestricted = has_selection_suffix(full_raw)
    for _, candidate in ipairs(decoded) do
        if unrestricted or candidate.max_rank <= 1 then
            eligible[#eligible + 1] = candidate
        end
    end
    local first = eligible[1]
    if
        not first
        or first.text:sub(1, #state.committed_text) ~= state.committed_text
        or #first.text <= #state.committed_text
    then
        return nil
    end
    if #eligible > 1 then
        if
            decoded.confidence_truncated
            or confidence.share(eligible, first) < config.early_commit_strong_threshold
            or first ~= decoded[1]
        then
            return nil
        end
    end
    local previous = first.path.previous
    return {
        text = first.text,
        base_raw_length = #full_raw,
        last_segment_start = previous and previous.raw_length or 0,
    }
end

local function try_empty_code_commit(env, state, full_before, appended, policy)
    local context = env.engine.context
    if not context:get_option("tiger_sentence_early_commit") or state.suspended then
        state.empty_code_pending = nil
        return false
    end
    local pending = state.empty_code_pending
        or capture_empty_code_candidate(state, full_before, policy)
    state.empty_code_pending = pending
    if not pending then
        return false
    end
    local full_raw = full_before .. appended
    if
        decoder.has_complete_candidate(
            full_raw,
            state.committed_text,
            policy.allow_duplicate,
            policy.high_frequency_limit
        )
    then
        state.empty_code_pending = nil
        return false
    end
    local extended_last_segment = full_raw:sub(pending.last_segment_start + 1)
    if lexicon.has_proper_prefix(extended_last_segment, policy.high_frequency_limit) then
        return false
    end
    local minimum = configured_integer(env, "tiger_sentence/min_retained_raw_length", 0)
    if minimum > 0 and #full_raw - pending.base_raw_length < minimum then
        return false
    end
    return commit_prefix(env, state, pending.text, pending.base_raw_length, full_raw)
end

local function plain_character(key_event, representation)
    if key_event:ctrl() or key_event:alt() or key_event:super() then
        return nil
    end
    if #representation == 1 and representation:match("[a-z]") then
        return representation
    end
    if representation == "semicolon" or representation == ";" then
        return ";"
    end
    if representation == "apostrophe" or representation == "'" then
        return "'"
    end
    if representation:match("^[0-9]$") then
        return representation
    end
    return representation:match("^KP_([0-9])$")
end

local function has_active_session(state)
    return state.committed_raw ~= ""
        or state.last_seen_raw ~= ""
        or next(state.trackers) ~= nil
        or state.suspended
end

local function handle_character(character, context, state, env)
    if not context:is_composing() and has_active_session(state) then
        reset_session(env)
        state = state_store.get(env)
    end
    if not context:is_composing() and (character == ";" or character == "'") then
        return 2
    end
    local input = context.input or ""
    if #input >= config.max_raw_length then
        return 1
    end

    local policy = decode_policy(env)
    local full_before = active_raw(state, input)
    local letter = character:match("^[a-z]$") ~= nil
    if not letter then
        state.empty_code_pending = nil
    elseif try_empty_code_commit(env, state, full_before, character, policy) then
        return 1
    end
    if try_early_commit(env, state, input .. character, policy) then
        return 1
    end
    return context:push_input(character) and 1 or 2
end

local function cycle_highlight(context, step)
    if not context:has_menu() then
        return false
    end
    local composition = context.composition
    if not composition or composition:empty() then
        return false
    end
    local segment = composition:back()
    local menu = segment.menu
    local count = menu and menu:candidate_count()
    if not count or count <= 0 then
        return false
    end
    local target = ((segment.selected_index or 0) + step) % count
    if type(context.highlight) == "function" and context:highlight(target) then
        return true
    end
    -- 旧绑定可能缺少此方法，或提供始终返回 false 的兼容实现
    segment.selected_index = target
    return segment.selected_index == target
end

local function handle_composition_key(representation, context, state, env)
    if representation == "Return" or representation == "KP_Enter" then
        env.engine:commit_text(context.input)
        context:clear()
        reset_session(env)
        return 1
    end
    if representation == "Escape" then
        context:clear()
        reset_session(env)
        return 1
    end
    if representation == "BackSpace" or representation == "Delete" then
        reset_evidence(state)
        state.empty_code_pending = nil
        return 2
    end
    if
        representation == "Tab"
        or representation == "ISO_Left_Tab"
        or representation == "Shift+Tab"
        or representation == "Shift+ISO_Left_Tab"
    then
        reset_evidence(state)
        state.empty_code_pending = nil
        state.suspended = true
        return cycle_highlight(context, representation == "Tab" and 1 or -1) and 1 or 2
    end
    if navigation_keys[representation] then
        reset_evidence(state)
        state.empty_code_pending = nil
        state.suspended = true
        return 2
    end
    if representation == "space" then
        if not context:has_menu() or not context:confirm_current_selection() then
            return 2
        end
        reset_session(env)
        return 1
    end
    return 2
end

function M.processor(key_event, env)
    if key_event:release() then
        return 2
    end
    local context = env.engine.context
    if context.input:find("[^a-z;'0-9]") then
        return 2
    end
    local state = state_store.get(env)
    local representation = key_event:repr()
    local character = plain_character(key_event, representation)
    if character then
        return handle_character(character, context, state, env)
    end
    if not context:is_composing() then
        return 2
    end
    return handle_composition_key(representation, context, state, env)
end

function M.deactivate(env)
    reset_session(env)
end

function M.translator(input, segment, env)
    -- 非整句编码交给 Rime 原生组件，包括标点菜单和斜杠分类符号
    if input:find("[^a-z;'0-9]") then
        return
    end
    local state = state_store.get(env)
    local policy = decode_policy(env)
    local raw = active_raw(state, input)
    local results = decoder.decode(
        raw,
        false,
        state.committed_text,
        policy.allow_duplicate,
        policy.high_frequency_limit
    )
    for _, item in ipairs(results) do
        -- 完整格网已按单字重码开关和显式选重筛选，提交前缀不改变续句资格
        if item.text:sub(1, #state.committed_text) == state.committed_text then
            local value = state.committed_text == "" and item.text
                or item.text:sub(#state.committed_text + 1)
            if value ~= "" then
                local candidate = Candidate("sentence", segment.start, segment._end, value, "")
                candidate.preedit = text.trim_segmented(item.segmented, #state.committed_raw)
                yield(candidate)
            end
        end
    end
end

return M
