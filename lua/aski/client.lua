--- Streaming chat client. curl is the only runtime dependency.

local config = require("aski.config")
local sse = require("aski.sse")

local M = {}

--- Build the chat-completions body for a selection and a question.
---@param context string
---@param question string
---@param cfg table
---@return table
function M.build_body(context, question, cfg)
  return {
    model = cfg.model,
    messages = {
      { role = "system", content = cfg.system_prompt },
      {
        role = "user",
        content = "Context:\n" .. context .. "\n\nQuestion:\n" .. question,
      },
    },
    stream = true,
    max_tokens = cfg.max_tokens,
  }
end

local function schedule_error(cb, message)
  vim.schedule(function()
    cb.on_error(message)
  end)
end

--- Stream a completion. The returned function cancels the request.
--- Callbacks run on the main loop. Deltas that arrive in one turn are merged.
---@param context string
---@param question string
---@param cb {on_delta:fun(text:string), on_done:fun(), on_error:fun(message:string)}
---@return fun()
function M.stream(context, question, cb)
  local cfg = config.resolve()
  if vim.fn.executable("curl") ~= 1 then
    schedule_error(cb, "curl is required but was not found on PATH")
    return function() end
  end
  if type(cfg.model) ~= "string" or cfg.model == "" then
    schedule_error(cb, "Aski: model must be a non-empty string")
    return function() end
  end
  if type(cfg.api_key) ~= "string" then
    schedule_error(cb, "Aski: api_key must be a string")
    return function() end
  end
  if cfg.api_key:find("[\r\n]") then
    schedule_error(cb, "Aski: api_key must be a single line")
    return function() end
  end
  if cfg.api_key == "" and cfg.base_url:find("api.openai.com", 1, true) then
    schedule_error(
      cb,
      "Set ASKI_API_KEY or OPENAI_API_KEY, or point ASKI_BASE_URL at an OpenAI-compatible server."
    )
    return function() end
  end

  local ok_body, body = pcall(vim.json.encode, M.build_body(context, question, cfg))
  if not ok_body then
    schedule_error(cb, "Could not encode the request: " .. tostring(body))
    return function() end
  end

  local header_file = vim.fn.tempname()
  local headers = {
    "Content-Type: application/json",
    "Expect:",
  }
  if cfg.api_key ~= "" then
    headers[#headers + 1] = "Authorization: Bearer " .. cfg.api_key
  end
  vim.fn.writefile(headers, header_file)
  pcall(vim.uv.fs_chmod, header_file, 384)

  local timeout_s = math.max(1, math.ceil((tonumber(cfg.timeout_ms) or 120000) / 1000))
  local connect_s = math.min(10, timeout_s)
  local url = cfg.base_url .. "/chat/completions"

  local state = sse.new()
  local pending = {}
  local scheduled = false
  local finished = false
  local stderr_parts = {}
  local cleaned = false
  local proc

  local function cleanup()
    if cleaned then
      return
    end
    cleaned = true
    pcall(vim.fn.delete, header_file)
  end

  local function finish_error(message)
    if finished then
      return
    end
    finished = true
    cleanup()
    cb.on_error(message)
  end

  local function finish_ok()
    if finished then
      return
    end
    finished = true
    cleanup()
    cb.on_done()
  end

  local function handle_events(events)
    if finished or not events then
      return
    end
    local pieces = {}
    local err
    local done = false
    for _, event in ipairs(events) do
      if event.kind == "delta" then
        pieces[#pieces + 1] = event.text
      elseif event.kind == "error" then
        err = event.message
      elseif event.kind == "done" then
        done = true
      end
    end
    if #pieces > 0 then
      cb.on_delta(table.concat(pieces))
    end
    if err then
      finish_error(err)
      return
    end
    if done then
      finish_ok()
    end
  end

  local function take_pending()
    local chunk = table.concat(pending)
    pending = {}
    scheduled = false
    return chunk
  end

  local function drain()
    if finished then
      pending = {}
      scheduled = false
      return
    end
    local chunk = take_pending()
    if chunk ~= "" then
      handle_events(sse.feed(state, chunk))
    end
  end

  local function on_stdout(_, data)
    if finished or data == nil or data == "" then
      return
    end
    pending[#pending + 1] = data
    if scheduled then
      return
    end
    scheduled = true
    vim.schedule(drain)
  end

  local function on_stderr(_, data)
    if data and data ~= "" then
      stderr_parts[#stderr_parts + 1] = data
    end
  end

  local function on_exit(result)
    vim.schedule(function()
      if not finished then
        local events = {}
        local chunk = take_pending()
        if chunk ~= "" then
          vim.list_extend(events, sse.feed(state, chunk))
        end
        vim.list_extend(events, sse.finish(state))
        handle_events(events)
      end
      cleanup()
      if finished then
        return
      end
      if result.code ~= 0 then
        local message = vim.trim(table.concat(stderr_parts))
        if message == "" then
          message = "request failed (" .. tostring(result.code) .. ")"
        end
        finish_error(message)
      else
        finish_ok()
      end
    end)
  end

  local ok_proc, started = pcall(vim.system, {
    "curl",
    "--silent",
    "--show-error",
    "--no-buffer",
    "--fail-with-body",
    "--connect-timeout",
    tostring(connect_s),
    "--max-time",
    tostring(timeout_s),
    "--expect100-timeout",
    "0",
    "--request",
    "POST",
    "--header",
    "@" .. header_file,
    "--data-binary",
    "@-",
    "--url",
    url,
  }, {
    stdin = body,
    stdout = on_stdout,
    stderr = on_stderr,
  }, on_exit)

  if not ok_proc then
    cleanup()
    schedule_error(cb, "Could not start curl: " .. tostring(started))
    return function() end
  end
  proc = started

  return function()
    if finished then
      return
    end
    finished = true
    cleanup()
    if proc and not proc:is_closing() then
      pcall(function()
        proc:kill("sigterm")
      end)
    end
  end
end

return M
