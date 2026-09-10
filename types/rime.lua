---@meta

---@class Config
---@field get_int fun(self: Config, path: string): integer|nil

---@class Menu
---@field candidate_count fun(self: Menu): integer

---@class CompositionSegment
---@field menu Menu
---@field selected_index integer

---@class Composition
---@field back fun(self: Composition): CompositionSegment
---@field empty fun(self: Composition): boolean

---@class Schema
---@field config Config

---@class Context
---@field input string
---@field composition Composition
---@field clear fun(self: Context)
---@field confirm_current_selection fun(self: Context): boolean
---@field get_option fun(self: Context, name: string): boolean
---@field get_property fun(self: Context, name: string): string
---@field set_property fun(self: Context, name: string, value: string)
---@field has_menu fun(self: Context): boolean
---@field highlight? fun(self: Context, index: integer): boolean
---@field is_composing fun(self: Context): boolean
---@field push_input fun(self: Context, value: string): boolean

---@class Engine
---@field context Context
---@field schema Schema
---@field commit_text fun(self: Engine, text: string)

---@class Env
---@field engine Engine
---@field tiger_sentence_state TigerSentenceSessionState|nil

---@class KeyEvent
---@field alt fun(self: KeyEvent): boolean
---@field caps fun(self: KeyEvent): boolean
---@field ctrl fun(self: KeyEvent): boolean
---@field release fun(self: KeyEvent): boolean
---@field repr fun(self: KeyEvent): string
---@field shift fun(self: KeyEvent): boolean
---@field super fun(self: KeyEvent): boolean

---@class Segment
---@field start integer
---@field _end integer

---@class Candidate
---@field preedit string

---@param candidate_type string
---@param start_pos integer
---@param end_pos integer
---@param text string
---@param comment string
---@return Candidate
function Candidate(candidate_type, start_pos, end_pos, text, comment) end

---@class RimeApi
---@field get_shared_data_dir fun(): string
---@field get_user_data_dir fun(): string
rime_api = {}

---@class Log
---@field error fun(message: string)
log = {}

---@param candidate Candidate
function yield(candidate) end
