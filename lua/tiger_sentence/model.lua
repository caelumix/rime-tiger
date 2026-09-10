-- 统一封装模型生命周期、有界查询缓存与生僻字惩罚
local config = require("tiger_sentence.config")
local reader = require("tiger_sentence.model.kn")
local ranks = require("tiger_sentence.data.ranks")
local text = require("tiger_sentence.text")

local M = {
    BOS = reader.BOS,
    EOS = reader.EOS,
    generation = 0,
}

---@type TigerSentenceKnModel|false|nil
local instance = false
---@type string|nil
local load_error = nil
local score_cache = {}
local score_keys = {}
local score_next = 1
local observed_cache = {}
local observed_keys = {}
local observed_next = 1
local isolation_cache = {}
local isolation_keys = {}
local isolation_next = 1

local function reset_query_caches()
    score_cache = {}
    score_keys = {}
    score_next = 1
    observed_cache = {}
    observed_keys = {}
    observed_next = 1
    isolation_cache = {}
    isolation_keys = {}
    isolation_next = 1
end

local function ensure()
    if instance ~= false then
        return instance
    end
    instance, load_error = reader.try_load()
    instance = instance or nil
    if not instance and log and log.error then
        log.error(
            "tiger_sentence：无法加载 n-gram 模型，改用无模型排序："
                .. tostring(load_error)
        )
    end
    return instance
end

function M.available()
    return ensure() ~= nil
end

local function remember(values, keys, next_index, limit, key, value)
    local old_key = keys[next_index]
    if old_key then
        values[old_key] = nil
    end
    values[key] = value
    keys[next_index] = key
    return next_index % limit + 1
end

function M.status()
    local loaded = ensure()
    if not loaded then
        return {
            loaded = false,
            path = nil,
            format = nil,
            bytes = 0,
            error = load_error,
        }
    end
    return {
        loaded = true,
        path = loaded.path,
        format = loaded.format,
        bytes = loaded.bytes,
        error = nil,
    }
end

function M.logp(previous2, previous1, target)
    local loaded = ensure()
    if not loaded then
        return 0
    end
    local key = previous2 .. "\0" .. previous1 .. "\0" .. target
    local cached = score_cache[key]
    if cached ~= nil then
        return cached
    end
    local value = loaded.logp(previous2, previous1, target)
    score_next =
        remember(score_cache, score_keys, score_next, config.score_cache_entries, key, value)
    return value
end

local function has_observed_bigram(loaded, previous, target)
    local key = previous .. "\0" .. target
    local cached = observed_cache[key]
    if cached ~= nil then
        return cached
    end
    local value = loaded.has_observed_bigram(previous, target)
    observed_next = remember(
        observed_cache,
        observed_keys,
        observed_next,
        config.observed_cache_entries,
        key,
        value
    )
    return value
end

function M.isolation_penalty(value)
    if value == "" or ranks.count == 0 then
        return 0
    end
    local cached = isolation_cache[value]
    if cached ~= nil then
        return cached
    end
    local loaded = ensure()
    if not loaded then
        return 0
    end
    local characters = text.chars(value)
    local penalty = 0
    for index = 1, #characters do
        if ranks.rank(characters[index]) > config.isolation_threshold then
            local left_hit = index > 1
                and has_observed_bigram(loaded, characters[index - 1], characters[index])
            local right_hit = index < #characters
                and has_observed_bigram(loaded, characters[index], characters[index + 1])
            if not left_hit and not right_hit then
                penalty = penalty + config.isolation_lambda
            end
        end
    end
    -- 只缓存短词，避免追加时产生的长句结果逐出反复出现的短词结果
    if #characters <= 6 then
        isolation_next = remember(
            isolation_cache,
            isolation_keys,
            isolation_next,
            config.isolation_cache_entries,
            value,
            penalty
        )
    end
    return penalty
end

function M.close()
    reset_query_caches()
    if instance then
        instance.close()
    end
    instance = false
    load_error = nil
    M.generation = M.generation + 1
end

return M
