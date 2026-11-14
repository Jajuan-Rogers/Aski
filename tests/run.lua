-- Headless checks for the parser, selection, client, and ask buffer.
local source = debug.getinfo(1, "S").source
local file = source:sub(1, 1) == "@" and source:sub(2) or source
local root = vim.fn.fnamemodify(file, ":h:h")
vim.cmd("cd " .. vim.fn.fnameescape(root))

local failures = {}
local passed = 0

local function check(cond, msg)
  if cond then
    passed = passed + 1
  else
    failures[#failures + 1] = msg
  end
end

local function eq(actual, expected, msg)
  if actual == expected then
    passed = passed + 1
  else
    failures[#failures + 1] = msg
      .. "\n  expected: "
      .. vim.inspect(expected)
      .. "\n  actual:   "
      .. vim.inspect(actual)
  end
end

local function finish(server)
  if server then
    pcall(function()
      server:kill("sigterm")
    end)
  end
  if #failures > 0 then
    io.stderr:write("\n" .. table.concat(failures, "\n\n") .. "\n")
    io.stderr:write(("\n%d passed, %d failed\n"):format(passed, #failures))
    vim.cmd("cquit 1")
  else
    io.stdout:write(("ok %d\n"):format(passed))
    vim.cmd("qa!")
  end
end

local function wait_for(timeout, pred, label)
  local ok = vim.wait(timeout, pred, 20)
  if not ok then
    failures[#failures + 1] = "timed out: " .. label
  end
  return ok
end

local function find_aski()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf) and vim.b[buf].aski == 1 then
      return buf
    end
  end
  return nil
end

local function answer_of(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local start_line
  for i, line in ipairs(lines) do
    if line == "### Answer" then
      start_line = i + 1
      break
    end
  end
  if not start_line then
    return ""
  end
  local parts = {}
  for i = start_line, #lines do
    parts[#parts + 1] = lines[i]
  end
  return table.concat(parts, "\n")
end

local function buffer_text(buf)
  return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
end

local function close_aski()
  local buf = find_aski()
  if buf then
    require("aski.ui").close(buf)
  end
end

local function run()
  check(package.loaded["aski"] == nil, "plugin file loaded the Lua module at startup")
  local visual_map = vim.fn.maparg("<leader>aq", "x")
  check(visual_map ~= "", "visual <leader>aq mapping is missing: " .. vim.inspect(visual_map))
  eq(vim.fn.maparg("<leader>aq", "n"), "", "normal-mode <leader>aq should be unset")
  eq(vim.fn.maparg("<Plug>(AskiAsk)", "x") ~= "" and true or false, true, "plug mapping missing")

  local sse = require("aski.sse")

  local function texts(events)
    local parts = {}
    local kinds = {}
    for _, event in ipairs(events) do
      kinds[#kinds + 1] = event.kind
      if event.kind == "delta" then
        parts[#parts + 1] = event.text
      end
    end
    return table.concat(parts), table.concat(kinds, ",")
  end

  local state = sse.new()
  local first = sse.feed(state, 'data: {"choices":[{"delta":{"content":"He')
  eq(#first, 0, "partial JSON line should wait")
  local second = sse.feed(state, 'llo"}}]}\n\ndata: [DONE]\n\n')
  local text, kinds = texts(second)
  eq(text, "Hello", "split SSE delta")
  eq(kinds, "delta,done", "split SSE kinds")

  state = sse.new()
  local crlf = sse.feed(state, 'data: {"choices":[{"delta":{"content":"A"}}]}\r\n\r\n')
  text, kinds = texts(crlf)
  eq(text, "A", "CRLF delta")

  state = sse.new()
  local ignored = sse.feed(state, ": ping\n\nevent: message\ndata: {\"choices\":[{\"delta\":{}}]}\n")
  eq(#ignored, 0, "comments and empty deltas produce no events")
  check(state.saw_data == true, "empty data line still marks the body as a stream")

  state = sse.new()
  local err_events = sse.feed(state, 'data: {"error":{"message":"nope"}}\n\n')
  eq(err_events[1] and err_events[1].kind, "error", "SSE error kind")
  eq(err_events[1] and err_events[1].message, "nope", "SSE error message")

  state = sse.new()
  sse.feed(state, '{"choices":[{"message":{"content":"plain')
  local finished = sse.finish(state)
  -- The partial chunk stayed in raw because it was not an SSE line, but finish
  -- only sees a complete body when the caller passes the whole payload.
  state = sse.new()
  sse.feed(state, '{"choices":[{"message":{"content":"plain reply"}}]}')
  finished = sse.finish(state)
  eq(finished[1] and finished[1].text, "plain reply", "non-stream JSON body")

  state = sse.new()
  sse.feed(state, '{"error":{"message":"bad key"}}')
  finished = sse.finish(state)
  eq(finished[1] and finished[1].message, "bad key", "non-stream JSON error")

  local started = vim.uv.hrtime()
  state = sse.new()
  local blob = {}
  for _ = 1, 2000 do
    blob[#blob + 1] = 'data: {"choices":[{"delta":{"content":"x"}}]}\n\n'
  end
  blob[#blob + 1] = "data: [DONE]\n\n"
  local bulk = sse.feed(state, table.concat(blob))
  local elapsed_ms = (vim.uv.hrtime() - started) / 1e6
  eq(#bulk, 2001, "bulk event count")
  check(elapsed_ms < 1500, ("parser took %.1fms"):format(elapsed_ms))

  local config = require("aski.config")
  vim.env.ASKI_MODEL = "from-env"
  vim.env.ASKI_BASE_URL = "http://127.0.0.1:9/v1/"
  vim.env.ASKI_API_KEY = "env-key"
  local resolved = config.resolve()
  eq(resolved.model, "from-env", "ASKI_MODEL")
  eq(resolved.base_url, "http://127.0.0.1:9/v1", "ASKI_BASE_URL strips the trailing slash")
  eq(resolved.api_key, "env-key", "ASKI_API_KEY")
  config.setup({ model = "override" })
  eq(config.resolve().model, "override", "setup overrides the environment")
  eq(config.resolve().api_key, "env-key", "unset api_key still comes from the environment")

  vim.cmd("enew")
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "alpha beta", "gamma delta" })
  vim.cmd([[execute "normal! gg0v4l\<Esc>"]])
  require("aski").ask_visual()
  local buf = find_aski()
  check(buf ~= nil, "charwise visual open")
  if buf then
    local shown = buffer_text(buf)
    check(shown:find("alpha", 1, true) ~= nil, "charwise context kept 'alpha'")
    check(shown:find("gamma", 1, true) == nil, "charwise context excluded the next line")
    require("aski.ui").close(buf)
  end

  vim.cmd([[execute "normal! ggVG\<Esc>"]])
  require("aski").ask_visual()
  buf = find_aski()
  check(buf ~= nil, "linewise visual open")
  if buf then
    local shown = buffer_text(buf)
    check(shown:find("alpha beta\ngamma delta", 1, true) ~= nil, "linewise context:\n" .. shown)
    require("aski.ui").close(buf)
  end

  vim.cmd("enew")
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "abcd", "efgh", "ijkl" })
  vim.cmd([[execute "normal! gg0\<C-v>lj\<Esc>"]])
  require("aski").ask_visual()
  buf = find_aski()
  check(buf ~= nil, "block visual open")
  if buf then
    local shown = buffer_text(buf)
    check(shown:find("ab\nef", 1, true) ~= nil, "block context:\n" .. shown)
    require("aski.ui").close(buf)
  end

  vim.cmd("enew")
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "   " })
  vim.cmd([[execute "normal! V\<Esc>"]])
  eq(vim.fn.visualmode(), "V", "linewise visual mode was recorded")
  local whitespace = table.concat(
    vim.fn.getregion(vim.fn.getpos("'<"), vim.fn.getpos("'>"), { type = vim.fn.visualmode() }),
    "\n"
  )
  eq(vim.trim(whitespace), "", "whitespace capture")
  require("aski").ask_visual()
  eq(find_aski(), nil, "whitespace selection does not open a buffer")

  vim.cmd("enew")
  vim.bo.filetype = "lua"
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "aaa", "bbb", "ccc" })
  vim.cmd("2,3Aski")
  buf = find_aski()
  check(buf ~= nil, ":Aski range opens a buffer")
  if buf then
    local shown = buffer_text(buf)
    check(shown:find("bbb\nccc", 1, true) ~= nil, "range context:\n" .. shown)
    check(shown:find("```lua", 1, true) ~= nil, "source filetype is the fence language")
    check(not shown:find("\naaa\n", 1, true), "range excluded the first line")
    local footer = vim.api.nvim_win_get_config(vim.api.nvim_get_current_win()).footer
    local footer_text = type(footer) == "string" and footer or vim.inspect(footer)
    check(footer_text:find("Enter", 1, true) ~= nil, "footer: " .. footer_text)
    require("aski.ui").close(buf)
  end

  local request_path = root .. "/tests/.last-request.json"
  os.remove(request_path)
  os.remove(request_path .. ".meta")
  local port
  local server_chunks = {}
  local server = vim.system({ "python3", "-u", root .. "/tests/mock_openai.py", "0" }, {
    env = { ASKI_TEST_REQUEST = request_path },
    stdout = function(_, data)
      if not data then
        return
      end
      vim.schedule(function()
        server_chunks[#server_chunks + 1] = data
        local joined = table.concat(server_chunks)
        local number = joined:match("(%d+)")
        if number then
          port = tonumber(number)
        end
      end)
    end,
    stderr = function(_, data)
      if data and data ~= "" then
        vim.schedule(function()
          io.stderr:write(data)
        end)
      end
    end,
  })

  if not wait_for(5000, function()
    return port ~= nil
  end, "mock server port") then
    finish(server)
    return
  end

  local health = vim.system({ "curl", "-sf", "http://127.0.0.1:" .. port .. "/health" }):wait(3000)
  eq(health.code, 0, "mock health: " .. vim.inspect(health))

  local client = require("aski.client")
  require("aski").setup({
    base_url = "http://127.0.0.1:" .. port .. "/v1",
    api_key = "test-key",
    model = "test-model",
    timeout_ms = 10000,
  })

  local deltas = 0
  local got = ""
  local done = false
  local err
  client.stream("ctx", "q", {
    on_delta = function(piece)
      deltas = deltas + 1
      got = got .. piece
    end,
    on_done = function()
      done = true
    end,
    on_error = function(message)
      err = message
      done = true
    end,
  })
  wait_for(5000, function()
    return done
  end, "stream completion")
  eq(err, nil, "stream error: " .. vim.inspect(err))
  eq(got, "Hello from Aski.\nSecond line.", "streamed text")
  check(deltas >= 2, "expected multiple deltas, got " .. tostring(deltas))

  local raw_request = table.concat(vim.fn.readfile(request_path), "\n")
  local decoded = vim.json.decode(raw_request)
  eq(decoded.model, "test-model", "request model")
  eq(decoded.stream, true, "request stream flag")
  eq(decoded.messages[1].role, "system", "system role")
  check(decoded.messages[2].content:find("Context:\nctx\n\nQuestion:\nq", 1, true) ~= nil, "prompt shape")
  local meta = vim.json.decode(table.concat(vim.fn.readfile(request_path .. ".meta"), "\n"))
  eq(meta.authorization, "Bearer test-key", "authorization header")
  eq(meta.content_type, "application/json", "content type")
  check(raw_request:find("test-key", 1, true) == nil, "api key leaked into the body")

  done, got, err = false, "", nil
  require("aski").setup({ model = "plain-model" })
  client.stream("ctx", "q", {
    on_delta = function(piece)
      got = got .. piece
    end,
    on_done = function()
      done = true
    end,
    on_error = function(message)
      err = message
      done = true
    end,
  })
  wait_for(5000, function()
    return done
  end, "plain JSON completion")
  eq(got, "plain reply", "non-stream HTTP body")
  eq(err, nil, "plain JSON error: " .. vim.inspect(err))

  done, err = false, nil
  require("aski").setup({ model = "error-model" })
  client.stream("ctx", "q", {
    on_delta = function() end,
    on_done = function()
      done = true
    end,
    on_error = function(message)
      err = message
      done = true
    end,
  })
  wait_for(5000, function()
    return done
  end, "error completion")
  eq(err, "bad key", "HTTP error message")

  local missed = ""
  require("aski").setup({ model = "slow-model" })
  local cancel = client.stream("ctx", "q", {
    on_delta = function(piece)
      missed = missed .. piece
    end,
    on_done = function() end,
    on_error = function() end,
  })
  vim.wait(80, function()
    return false
  end)
  cancel()
  vim.wait(1200, function()
    return false
  end)
  eq(missed, "", "cancelled request delivered text")

  require("aski").setup({
    base_url = "https://api.openai.com/v1",
    api_key = "",
    model = "gpt-4o-mini",
  })
  done, err = false, nil
  client.stream("ctx", "q", {
    on_delta = function() end,
    on_done = function()
      done = true
    end,
    on_error = function(message)
      err = message
      done = true
    end,
  })
  wait_for(1000, function()
    return done
  end, "missing key")
  check(type(err) == "string" and err:find("ASKI_API_KEY", 1, true) ~= nil, "missing key message: " .. vim.inspect(err))

  require("aski").setup({
    base_url = "http://127.0.0.1:" .. port .. "/v1",
    api_key = "test-key",
    model = "echo-model",
    timeout_ms = 10000,
  })

  vim.cmd("enew")
  vim.bo.filetype = "lua"
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "local value = 42" })
  local plug = vim.api.nvim_replace_termcodes("<Plug>(AskiAsk)", true, false, true)
  vim.api.nvim_feedkeys("ggVG" .. plug, "x", false)
  if not wait_for(2000, function()
    return find_aski() ~= nil
  end, "visual mapping opens the ask buffer") then
    finish(server)
    return
  end
  buf = find_aski()
  local opened = buffer_text(buf)
  check(opened:find("local value = 42", 1, true) ~= nil, "mapping showed the selection:\n" .. opened)
  check(opened:find("```lua", 1, true) ~= nil, "mapping used the lua fence")
  local qline
  for i, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
    if line == "### Question" then
      qline = i + 2
    end
  end
  check(qline ~= nil, "question line missing")
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_buf_set_lines(buf, qline - 1, qline, false, { "What does this return?" })
  -- Headless Neovim has no TTY, so startinsert does not change mode. Enter is
  -- also mapped in normal mode, which is the same submit path.
  local enter = vim.api.nvim_replace_termcodes("<CR>", true, false, true)
  vim.api.nvim_feedkeys(enter, "x", false)
  if not wait_for(5000, function()
    if not vim.api.nvim_buf_is_valid(buf) or require("aski.ui").is_busy(buf) then
      return false
    end
    return answer_of(buf):find("The selection starts with `local value = 42`", 1, true) ~= nil
  end, "visual mapping answer: " .. answer_of(buf)) then
    finish(server)
    return
  end

  local answer = answer_of(buf)
  check(answer:find("You asked: What does this return?", 1, true) ~= nil, "answer echoes the question:\n" .. answer)
  check(answer:find("The selection starts with `local value = 42`", 1, true) ~= nil, "answer cites the selection:\n" .. answer)
  eq(require("aski.ui").is_busy(buf), false, "buffer still busy after the answer")
  eq(vim.bo[buf].modifiable, true, "buffer stays editable after the answer")
  local cr_map = vim.fn.maparg("<CR>", "i", false, true)
  check(type(cr_map) == "table" and cr_map.buffer == 1, "Enter is a buffer-local insert mapping")

  close_aski()

  vim.cmd("enew")
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "keep me" })
  vim.cmd([[execute "normal! ggV\<Esc>"]])
  require("aski").ask_visual()
  buf = find_aski()
  check(buf ~= nil, "empty-question buffer")
  if buf then
    local qline
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    for i, line in ipairs(lines) do
      if line == "### Question" then
        qline = i + 2
      end
    end
    vim.api.nvim_win_set_cursor(0, { qline, 0 })
    vim.api.nvim_buf_set_lines(buf, qline - 1, qline, false, { "   " })
    os.remove(request_path)
    require("aski.ui").submit(buf)
    vim.wait(250, function()
      return false
    end)
    eq(vim.fn.filereadable(request_path), 0, "blank question sent a request")
    eq(require("aski.ui").is_busy(buf), false, "blank question marked the buffer busy")
    require("aski.ui").close(buf)
  end

  os.remove(request_path)
  os.remove(request_path .. ".meta")
  finish(server)
end

local ok, err = xpcall(run, debug.traceback)
if not ok then
  io.stderr:write(tostring(err) .. "\n")
  vim.cmd("cquit 1")
end
