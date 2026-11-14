--- Incremental parser for OpenAI-style chat streams.
--- Accepts server-sent events and a single JSON body.

local M = {}

local MAX_RAW = 2000000

function M.new()
  return {
    buf = "",
    raw = "",
    saw_data = false,
  }
end

local function strip_cr(line)
  if line:sub(-1) == "\r" then
    return line:sub(1, -2)
  end
  return line
end

--- Turn one SSE data payload, or a whole JSON body, into an event.
---@param payload string
---@return table|nil
function M.parse_payload(payload)
  if payload == "[DONE]" then
    return { kind = "done" }
  end
  local ok, decoded = pcall(vim.json.decode, payload)
  if not ok or type(decoded) ~= "table" then
    return nil
  end
  if type(decoded.error) == "table" then
    local message = decoded.error.message
    if type(message) ~= "string" or message == "" then
      message = "request failed"
    end
    return { kind = "error", message = message }
  end
  local choices = decoded.choices
  local choice = type(choices) == "table" and choices[1] or nil
  if type(choice) ~= "table" then
    return nil
  end
  local delta = choice.delta
  if type(delta) == "table" and type(delta.content) == "string" and delta.content ~= "" then
    return { kind = "delta", text = delta.content }
  end
  local message = choice.message
  if type(message) == "table" and type(message.content) == "string" and message.content ~= "" then
    return { kind = "delta", text = message.content }
  end
  return nil
end

--- Parse one line. The second return is true when the line is an SSE data line.
---@param line string
---@return table|nil
---@return boolean
local function parse_line(line)
  if line:sub(1, 5) ~= "data:" then
    return nil, false
  end
  local payload = line:sub(6)
  if payload:sub(1, 1) == " " then
    payload = payload:sub(2)
  end
  if payload == "" then
    return nil, true
  end
  return M.parse_payload(payload), true
end

--- Feed the next chunk. Events from a single chunk are returned together.
---@param state table
---@param chunk string|nil
---@return table[]
function M.feed(state, chunk)
  if chunk == nil or chunk == "" then
    return {}
  end
  if not state.saw_data then
    if #state.raw + #chunk > MAX_RAW then
      state.saw_data = true
      state.raw = nil
      return { { kind = "error", message = "response exceeded 2MB" } }
    end
    state.raw = state.raw .. chunk
  end

  state.buf = state.buf .. chunk
  local events = {}
  while true do
    local nl = state.buf:find("\n", 1, true)
    if not nl then
      break
    end
    local line = strip_cr(state.buf:sub(1, nl - 1))
    state.buf = state.buf:sub(nl + 1)
    local event, is_data = parse_line(line)
    if is_data then
      state.saw_data = true
      state.raw = nil
    end
    if event then
      events[#events + 1] = event
    end
  end
  return events
end

--- Flush a trailing line and, if this was not a stream, the JSON body.
---@param state table
---@return table[]
function M.finish(state)
  local events = {}
  if state.buf ~= "" then
    local event, is_data = parse_line(strip_cr(state.buf))
    state.buf = ""
    if is_data then
      state.saw_data = true
      state.raw = nil
    end
    if event then
      events[#events + 1] = event
    end
  end
  if not state.saw_data and type(state.raw) == "string" and vim.trim(state.raw) ~= "" then
    local raw = state.raw
    state.raw = nil
    local event = M.parse_payload(raw)
    if event then
      events[#events + 1] = event
    else
      events[#events + 1] = { kind = "error", message = "could not read the model response" }
    end
  end
  return events
end

return M
