-- 计算可见前缀及其原始编码边界的置信度
local M = {}

---@class TigerSentenceConfidenceEvidence
---@field total number
---@field weights table<integer, number>

local function eligible(candidate, required_prefix)
    return not required_prefix
        or required_prefix == ""
        or candidate.text:sub(1, #required_prefix) == required_prefix
end

local function distribution(candidates, required_prefix)
    local max_score = nil
    for index = 1, #candidates do
        local candidate = candidates[index]
        if eligible(candidate, required_prefix) then
            local score = candidate.confidence_score
            max_score = max_score and math.max(max_score, score) or score
        end
    end
    if not max_score then
        return nil
    end
    local result = { total = 0, weights = {} }
    for index = 1, #candidates do
        local candidate = candidates[index]
        if eligible(candidate, required_prefix) then
            local score = candidate.confidence_score
            local weight = math.exp(score - max_score)
            result.weights[index] = weight
            result.total = result.total + weight
        end
    end
    return result
end

function M.prefixes(candidates, required_prefix, closed_threshold)
    local evidence = distribution(candidates, required_prefix)
    if not evidence then
        return {}, 0
    end
    local by_boundary = {}
    local boundary_mass = {}
    local result = {}
    for index = 1, #candidates do
        local candidate = candidates[index]
        local weight = evidence.weights[index]
        if weight then
            local state = candidate.path
            while state and state.raw_length > 0 do
                local prefix = candidate.text:sub(1, state.text_length)
                if prefix ~= "" then
                    local boundary = by_boundary[state.raw_length]
                    if not boundary then
                        boundary = {}
                        by_boundary[state.raw_length] = boundary
                    end
                    local item = boundary[prefix]
                    if not item then
                        item = {
                            text = prefix,
                            raw_length = state.raw_length,
                            mass = 0,
                        }
                        boundary[prefix] = item
                        result[#result + 1] = item
                    end
                    item.mass = item.mass + weight
                    boundary_mass[state.raw_length] = (boundary_mass[state.raw_length] or 0)
                        + weight
                end
                state = state.previous
            end
        end
    end
    local top_share = 0
    for index = 1, #candidates do
        local weight = evidence.weights[index]
        if weight then
            top_share = math.max(top_share, weight / evidence.total)
        end
    end
    for _, item in ipairs(result) do
        item.share = item.mass / evidence.total
        item.boundary_share = (boundary_mass[item.raw_length] or 0) / evidence.total
        item.boundary_closed = item.boundary_share >= closed_threshold
        item.mass = nil
    end
    return result, top_share
end

function M.share(candidates, candidate, required_prefix)
    local evidence = distribution(candidates, required_prefix)
    if not evidence then
        return 0
    end
    for index = 1, #candidates do
        if candidates[index] == candidate then
            return (evidence.weights[index] or 0) / evidence.total
        end
    end
    return 0
end

return M
