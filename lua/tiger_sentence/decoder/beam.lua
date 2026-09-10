-- 管理 Beam 状态、文本去重与精确前 k 项剪枝
local config = require("tiger_sentence.config")

local M = {}
local aggregate_threshold = config.aggregate_threshold

---@class TigerSentenceBeamState
---@field score number
---@field mass_score number
---@field text string
---@field prev2 string
---@field prev1 string
---@field max_rank integer
---@field supplement_state integer
---@field supplement_score number
---@field previous TigerSentenceBeamState|nil
---@field text_length integer
---@field raw_length integer
---@field edge_count integer

---@class TigerSentenceBeamBucket
---@field [integer] TigerSentenceBeamState
---@field _best table<string, TigerSentenceBeamState>|nil
---@field _mass table<string, number>|nil
---@field _order string[]|nil
---@field _truncated boolean|nil
---@field _frozen boolean|nil

---@return TigerSentenceBeamBucket
function M.new_bucket()
    return {}
end

---@param left TigerSentenceBeamState
---@param right TigerSentenceBeamState
---@return boolean
function M.rank_first(left, right)
    local left_rank = left.max_rank
    local right_rank = right.max_rank
    if left_rank ~= right_rank then
        return left_rank < right_rank
    end
    if left.score == right.score then
        return left.text < right.text
    end
    return left.score > right.score
end

function M.score_first(left, right)
    if left.score == right.score then
        local left_rank = left.max_rank
        local right_rank = right.max_rank
        if left_rank ~= right_rank then
            return left_rank < right_rank
        end
        return left.text < right.text
    end
    return left.score > right.score
end

function M.no_model(left, right)
    local left_rank = left.max_rank
    local right_rank = right.max_rank
    if left_rank ~= right_rank then
        return left_rank < right_rank
    end
    local left_edges = left.edge_count
    local right_edges = right.edge_count
    if left_edges ~= right_edges then
        return left_edges < right_edges
    end
    if left.score == right.score then
        return left.text < right.text
    end
    return left.score > right.score
end

local function duplicate_better(item, previous)
    local item_rank = item.max_rank
    local previous_rank = previous.max_rank
    if item_rank ~= previous_rank then
        return item_rank < previous_rank
    end
    if item.score ~= previous.score then
        return item.score > previous.score
    end
    return item.edge_count < previous.edge_count
end

local function logsumexp(left, right)
    local maximum = math.max(left, right)
    return maximum + math.log(math.exp(left - maximum) + math.exp(right - maximum))
end

local function add_aggregated(bucket, item)
    local best = bucket._best
    local mass = bucket._mass
    local order = bucket._order
    ---@cast best table<string, TigerSentenceBeamState>
    ---@cast mass table<string, number>
    ---@cast order string[]
    local key = item.text
    local previous = best[key]
    local item_mass = item.mass_score
    if not previous then
        best[key] = item
        mass[key] = item_mass
        order[#order + 1] = key
    else
        mass[key] = logsumexp(mass[key], item_mass)
        if duplicate_better(item, previous) then
            best[key] = item
        end
    end
    best[key].mass_score = mass[key]
end

local function aggregate(bucket)
    if bucket._best then
        return
    end

    bucket._best = {}
    bucket._mass = {}
    bucket._order = {}
    for index = 1, #bucket do
        add_aggregated(bucket, bucket[index])
        bucket[index] = nil
    end
end

---@param bucket TigerSentenceBeamBucket
---@param item TigerSentenceBeamState
function M.add(bucket, item)
    if bucket._best then
        add_aggregated(bucket, item)
        return
    end
    bucket[#bucket + 1] = item
    if #bucket >= aggregate_threshold then
        aggregate(bucket)
    end
end

local function sift_worst_up(heap, index, better)
    while index > 1 do
        local parent = math.floor(index / 2)
        if not better(heap[parent], heap[index]) then
            return
        end
        heap[parent], heap[index] = heap[index], heap[parent]
        index = parent
    end
end

local function sift_worst_down(heap, index, better)
    while true do
        local left = index * 2
        if left > #heap then
            return
        end
        local right = left + 1
        local worse = left
        if right <= #heap and better(heap[left], heap[right]) then
            worse = right
        end
        if not better(heap[index], heap[worse]) then
            return
        end
        heap[index], heap[worse] = heap[worse], heap[index]
        index = worse
    end
end

---@generic T
---@param values T[]
---@param limit integer
---@param better fun(left: T, right: T): boolean
---@return T[]
function M.select(values, limit, better)
    local heap = {}
    for index = 1, #values do
        local item = values[index]
        if #heap < limit then
            heap[#heap + 1] = item
            sift_worst_up(heap, #heap, better)
        elseif better(item, heap[1]) then
            heap[1] = item
            sift_worst_down(heap, 1, better)
        end
    end
    table.sort(heap, better)
    return heap
end

---@param bucket TigerSentenceBeamBucket
---@param limit integer
---@return TigerSentenceBeamBucket
function M.limit(bucket, limit, better)
    -- 增量扩展只写入新位置，已处理位置冻结后只会被重复读取
    if bucket._frozen then
        return bucket
    end
    aggregate(bucket)

    local values = {}
    local order = bucket._order
    local best = bucket._best
    ---@cast order string[]
    ---@cast best table<string, TigerSentenceBeamState>
    for index = 1, #order do
        values[index] = best[order[index]]
    end

    local truncated = #values > limit
    if #values > limit then
        values = M.select(values, limit, better)
    else
        table.sort(values, better)
    end

    ---@cast values TigerSentenceBeamBucket
    values._truncated = truncated
    values._frozen = true
    return values
end

return M
