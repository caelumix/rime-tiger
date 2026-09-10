-- 加载补充语料，并提供增量匹配与提前上屏保护
local config = require("tiger_sentence.config")
local text = require("tiger_sentence.text")

local M = {}
local file_name = "tiger_sentence.supplement.txt"

local function reward_for_weight(weight)
    local bounded = math.max(1, math.min(config.supplement_max_weight, weight))
    local reward = config.supplement_base_reward
        + config.supplement_weight_scale * math.log(bounded / config.supplement_default_weight)
    return math.max(0, math.min(config.supplement_max_reward, reward))
end

local function empty(path, load_error)
    return {
        nodes = { { transitions = {}, failure = 1, reward = 0 } },
        path = path,
        count = 0,
        error = load_error,
    }
end

function M.build(entries, path)
    local matcher = empty(path, nil)
    local nodes = matcher.nodes
    for value, weight in pairs(entries) do
        local reward = reward_for_weight(weight)
        if reward > 0 then
            local state = 1
            local characters = text.chars(value)
            for index = 1, #characters do
                local character = characters[index]
                local next_state = nodes[state].transitions[character]
                if not next_state then
                    next_state = #nodes + 1
                    nodes[state].transitions[character] = next_state
                    nodes[next_state] = {
                        transitions = {},
                        failure = 1,
                        reward = 0,
                    }
                end
                state = next_state
            end
            nodes[state].reward = math.max(nodes[state].reward, reward)
            matcher.count = matcher.count + 1
        end
    end
    if matcher.count == 0 then
        return matcher
    end

    local queue = {}
    local head = 1
    for _, child in pairs(nodes[1].transitions) do
        queue[#queue + 1] = child
    end
    while head <= #queue do
        local current = queue[head]
        head = head + 1
        for character, child in pairs(nodes[current].transitions) do
            local fallback = nodes[current].failure
            while fallback ~= 1 and not nodes[fallback].transitions[character] do
                fallback = nodes[fallback].failure
            end
            local target = nodes[fallback].transitions[character]
            nodes[child].failure = target or 1
            nodes[child].reward = math.max(nodes[child].reward, nodes[nodes[child].failure].reward)
            queue[#queue + 1] = child
        end
    end
    return matcher
end

function M.load(path)
    local handle, open_error = io.open(path, "rb")
    if not handle then
        return empty(path, open_error)
    end
    local content, read_error = handle:read("*a")
    local closed, close_error = handle:close()
    if not content or not closed then
        return empty(path, read_error or close_error)
    end
    content = content:gsub("^\239\187\191", ""):gsub("\r\n", "\n"):gsub("\r", "\n")

    local entries = {}
    for raw_line in (content .. "\n"):gmatch("(.-)\n") do
        local line = raw_line:match("^%s*(.-)%s*$")
        if line ~= "" and line:sub(1, 1) ~= "#" then
            local value, raw_weight = line:match("^(%S+)%s*(.-)$")
            ---@type number|nil
            local weight = config.supplement_default_weight
            if raw_weight ~= "" then
                weight = raw_weight:match("^%d+$") and tonumber(raw_weight) or nil
            end
            if utf8.len(value) and weight and weight > 0 then
                entries[value] = weight
            end
        end
    end
    return M.build(entries, path)
end

function M.load_default()
    if not rime_api then
        return empty(nil, nil)
    end
    local directory = rime_api.get_user_data_dir()
    if directory == "" then
        return empty(nil, nil)
    end
    local separator = "/"
    if directory:sub(-1) == "/" or directory:sub(-1) == "\\" then
        separator = ""
    end
    return M.load(directory .. separator .. file_name)
end

function M.advance(matcher, state, character)
    -- 调用方仅在非空词表下进入匹配，state 始终来自同一 matcher
    local nodes = matcher.nodes
    local current = state
    while current ~= 1 and not nodes[current].transitions[character] do
        current = nodes[current].failure
    end
    current = nodes[current].transitions[character] or 1
    return current, nodes[current].reward
end

M.reward_for_weight = reward_for_weight
return M
