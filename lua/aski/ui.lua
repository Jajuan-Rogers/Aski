--- Floating ask buffer: selection, question, then the streamed answer.

local client = require("aski.client")

local M = {}

local ns = vim.api.nvim_create_namespace("aski")
local states = {}

local function code_fence(text)
  local ticks = 3
  for run in text:gmatch("`+") do
    if #run >= ticks then
      ticks = #run + 1
    end
  end
  return string.rep("`", ticks)
end

local function sanitize_lang(lang)
  if type(lang) ~= "string" then
    return ""
  end
  if lang:match("^[%w_+%-%.#]+$") then
    return lang
  end
  return ""
end

local function mark_row(buf, id)
  if not id then
    return nil
  end
  local ok, mark = pcall(vim.api.nvim_buf_get_extmark_by_id, buf, ns, id, {})
  if not ok or type(mark) ~= "table" or mark[1] == nil then
    return nil
  end
  return mark[1]
end

local function geometry()
  local cols = math.max(vim.o.columns, 1)
  local rows = math.max(vim.o.lines, 1)
  local width = math.floor(cols * 0.72)
  local height = math.floor(rows * 0.72)
  if width < 24 then
    width = cols - 2
  end
  if height < 10 then
    height = rows - 2
  end
  width = math.min(math.max(width, 1), math.max(1, cols - 2))
  height = math.min(math.max(height, 1), math.max(1, rows - 2))
  local row = math.max(0, math.floor((rows - height) / 2) - 1)
  local col = math.max(0, math.floor((cols - width) / 2))
  if row + height > rows - 1 then
    row = math.max(0, rows - height - 1)
  end
  return width, height, row, col
end

local function set_footer(st, text)
  if not st or not vim.api.nvim_win_is_valid(st.win) then
    return
  end
  st.config.footer = " " .. text .. " "
  pcall(vim.api.nvim_win_set_config, st.win, st.config)
end

local function is_busy(buf)
  local st = states[buf]
  return st ~= nil and st.busy == true
end

--- Programmatic edits should not run the user's TextChanged hooks.
local function mutate(buf, fn)
  local prev = vim.o.eventignore
  if prev == "" then
    vim.o.eventignore = "TextChanged,TextChangedI,TextChangedP,TextChangedT"
  else
    vim.o.eventignore = prev .. ",TextChanged,TextChangedI,TextChangedP,TextChangedT"
  end
  vim.bo[buf].modifiable = true
  local ok, err = pcall(fn)
  if is_busy(buf) then
    vim.bo[buf].modifiable = false
  end
  vim.o.eventignore = prev
  if not ok then
    error(err)
  end
end

local function question_text(buf, st)
  local q = mark_row(buf, st.q_mark)
  local a = mark_row(buf, st.a_mark)
  if not q or not a or a <= q then
    return nil
  end
  local lines = vim.api.nvim_buf_get_lines(buf, q, a, false)
  return vim.trim(table.concat(lines, "\n"))
end

local function replace_answer(buf, st, lines)
  local header = mark_row(buf, st.a_mark)
  if not header then
    return false
  end
  mutate(buf, function()
    pcall(vim.api.nvim_buf_call, buf, function()
      pcall(vim.cmd, "undojoin")
    end)
    vim.api.nvim_buf_set_lines(buf, header + 1, -1, false, lines)
  end)
  return true
end

local function append_answer(buf, st, text)
  local header = mark_row(buf, st.a_mark)
  if not header then
    return
  end
  mutate(buf, function()
    local count = vim.api.nvim_buf_line_count(buf)
    if count < header + 2 then
      vim.api.nvim_buf_set_lines(buf, header + 1, -1, false, { "" })
      count = vim.api.nvim_buf_line_count(buf)
    end
    local last = vim.api.nvim_buf_get_lines(buf, count - 1, count, false)[1] or ""
    local parts = vim.split(text, "\n", { plain = true })
    parts[1] = last .. parts[1]
    pcall(vim.api.nvim_buf_call, buf, function()
      pcall(vim.cmd, "undojoin")
    end)
    vim.api.nvim_buf_set_lines(buf, count - 1, count, false, parts)
  end)
end

local function reveal_end(win, buf)
  if not vim.api.nvim_win_is_valid(win) then
    return
  end
  local height = vim.api.nvim_win_get_height(win)
  local count = vim.api.nvim_buf_line_count(buf)
  local topline = math.max(1, count - height + 1)
  pcall(vim.api.nvim_win_call, win, function()
    local view = vim.fn.winsaveview()
    view.topline = topline
    vim.fn.winrestview(view)
  end)
end

local function reveal_answer(st, buf)
  local header = mark_row(buf, st.a_mark)
  if not header or not vim.api.nvim_win_is_valid(st.win) then
    return
  end
  local height = vim.api.nvim_win_get_height(st.win)
  local count = vim.api.nvim_buf_line_count(buf)
  local topline = 1
  if count > height then
    -- Leave the question visible above the answer when the selection is long.
    topline = math.max(1, header + 1 - math.max(3, math.floor(height * 0.45)))
    local max_top = math.max(1, count - height + 1)
    if topline > max_top then
      topline = max_top
    end
  end
  pcall(vim.api.nvim_win_call, st.win, function()
    local view = vim.fn.winsaveview()
    view.topline = topline
    vim.fn.winrestview(view)
  end)
  local cursor = math.min(count, header + 2)
  pcall(vim.api.nvim_win_set_cursor, st.win, { cursor, 0 })
end

local function stop_job(st)
  if st.cancel then
    local cancel = st.cancel
    st.cancel = nil
    cancel()
  end
  st.busy = false
end

function M.is_busy(buf)
  return is_busy(buf)
end

function M.cancel(buf)
  local st = states[buf]
  if not st then
    return
  end
  if not st.busy then
    M.close(buf)
    return
  end
  stop_job(st)
  if vim.api.nvim_buf_is_valid(buf) then
    vim.bo[buf].modifiable = true
  end
  set_footer(st, "Cancelled · Enter sends again · q closes")
end

function M.close(buf)
  local st = states[buf]
  if st then
    stop_job(st)
    states[buf] = nil
  end
  pcall(vim.cmd, "stopinsert")
  if st and vim.api.nvim_win_is_valid(st.win) then
    pcall(vim.api.nvim_win_close, st.win, true)
  end
  if vim.api.nvim_buf_is_valid(buf) then
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end
end

function M.submit(buf)
  local st = states[buf]
  if not st or st.busy then
    return
  end
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local question = question_text(buf, st)
  if question == nil then
    set_footer(st, "Buffer layout changed · press q and try again")
    return
  end
  if question == "" then
    set_footer(st, "Type a question, then press Enter")
    return
  end

  pcall(vim.cmd, "stopinsert")
  if not replace_answer(buf, st, { "" }) then
    set_footer(st, "Buffer layout changed · press q and try again")
    return
  end

  st.busy = true
  st.streaming = false
  vim.bo[buf].modifiable = false
  set_footer(st, "Sending…")

  st.cancel = client.stream(st.context, question, {
    on_delta = function(text)
      if not vim.api.nvim_buf_is_valid(buf) or not states[buf] then
        return
      end
      append_answer(buf, st, text)
      reveal_end(st.win, buf)
      if not st.streaming then
        st.streaming = true
        set_footer(st, "Streaming…")
      end
    end,
    on_done = function()
      if not states[buf] then
        return
      end
      st.busy = false
      st.cancel = nil
      if vim.api.nvim_buf_is_valid(buf) then
        vim.bo[buf].modifiable = true
        local header = mark_row(buf, st.a_mark)
        local body = ""
        if header then
          body = vim.trim(table.concat(vim.api.nvim_buf_get_lines(buf, header + 1, -1, false), "\n"))
        end
        if body == "" then
          replace_answer(buf, st, { "_The model returned an empty response._" })
        end
        reveal_answer(st, buf)
      end
      set_footer(st, "Done · edit the question and press Enter to ask again · q closes")
    end,
    on_error = function(message)
      if not states[buf] then
        return
      end
      st.busy = false
      st.cancel = nil
      if vim.api.nvim_buf_is_valid(buf) then
        vim.bo[buf].modifiable = true
        local header = mark_row(buf, st.a_mark)
        local existing = ""
        if header then
          existing = table.concat(vim.api.nvim_buf_get_lines(buf, header + 1, -1, false), "\n")
        end
        local prefix = vim.trim(existing)
        local shown = prefix == "" and ("**Error:** " .. message) or (existing .. "\n\n**Error:** " .. message)
        replace_answer(buf, st, vim.split(shown, "\n", { plain = true }))
        reveal_answer(st, buf)
      end
      set_footer(st, "Error · edit the question and press Enter · q closes")
    end,
  })
end

--- Open the ask buffer for a captured selection.
---@param context string
---@param opts {filetype?:string, truncated?:boolean}|nil
---@return integer buf
---@return integer win
function M.open(context, opts)
  opts = opts or {}
  local lang = sanitize_lang(opts.filetype)
  local fence = code_fence(context)
  local lines = {}
  if opts.truncated then
    lines[#lines + 1] = "### Context (truncated)"
  else
    lines[#lines + 1] = "### Context"
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = lang ~= "" and (fence .. lang) or fence
  local context_lines = vim.split(context, "\n", { plain = true })
  for i = 1, #context_lines do
    lines[#lines + 1] = context_lines[i]
  end
  lines[#lines + 1] = fence
  lines[#lines + 1] = ""
  lines[#lines + 1] = "### Question"
  lines[#lines + 1] = ""
  local q_row = #lines
  lines[#lines + 1] = ""
  lines[#lines + 1] = ""
  local a_row = #lines
  lines[#lines + 1] = "### Answer"
  lines[#lines + 1] = ""

  local buf = vim.api.nvim_create_buf(false, true)
  local seq = (vim.g.aski_seq or 0) + 1
  vim.g.aski_seq = seq
  pcall(vim.api.nvim_buf_set_name, buf, "aski://ask/" .. seq)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].undofile = false
  vim.bo[buf].modeline = false
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].filetype = "markdown"
  vim.bo[buf].formatoptions = ""
  vim.bo[buf].comments = ""
  vim.bo[buf].commentstring = ""
  vim.bo[buf].indentexpr = ""
  vim.bo[buf].autoindent = false
  vim.bo[buf].smartindent = false
  vim.bo[buf].cindent = false
  vim.bo[buf].textwidth = 0
  vim.b[buf].aski = 1

  local q_mark = vim.api.nvim_buf_set_extmark(buf, ns, q_row, 0, { right_gravity = false })
  local a_mark = vim.api.nvim_buf_set_extmark(buf, ns, a_row, 0, { right_gravity = true })

  local width, height, row, col = geometry()
  local win_config = {
    relative = "editor",
    width = width,
    height = height,
    row = row,
    col = col,
    style = "minimal",
    border = "rounded",
    title = " Aski ",
    title_pos = "center",
    footer = " Enter send · q close ",
    footer_pos = "center",
    zindex = 40,
  }
  local win = vim.api.nvim_open_win(buf, true, win_config)
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  vim.wo[win].breakindent = true
  vim.wo[win].cursorline = true
  vim.wo[win].conceallevel = 0
  vim.wo[win].spell = false
  vim.wo[win].scrolloff = 0
  vim.wo[win].list = false

  states[buf] = {
    win = win,
    config = win_config,
    context = context,
    q_mark = q_mark,
    a_mark = a_mark,
    busy = false,
    cancel = nil,
    streaming = false,
  }

  local function map(mode, lhs, rhs)
    vim.keymap.set(mode, lhs, rhs, { buffer = buf, nowait = true, silent = true })
  end
  map({ "n", "i" }, "<CR>", function()
    M.submit(buf)
  end)
  map("n", "q", function()
    M.close(buf)
  end)
  map({ "n", "i" }, "<C-c>", function()
    M.cancel(buf)
  end)

  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = buf,
    callback = function()
      local st = states[buf]
      if not st then
        return
      end
      stop_job(st)
      states[buf] = nil
    end,
  })

  vim.api.nvim_win_set_cursor(win, { q_row + 1, 0 })
  -- A mapping that ran as `:` restores Normal mode after the scheduler drains,
  -- so wait one timer tick before entering insert mode.
  vim.defer_fn(function()
    if vim.api.nvim_win_is_valid(win) and vim.api.nvim_get_current_win() == win then
      vim.cmd("startinsert")
    end
  end, 0)

  return buf, win
end

return M
