--- Ask an LLM about text selected in Neovim.

local config = require("aski.config")
local ui = require("aski.ui")

local M = {}

local MAX_CONTEXT = 200000

local function nvim_ok()
  local version = vim.version()
  if version.major > 0 or version.minor >= 10 then
    return true
  end
  vim.notify("Aski requires Neovim 0.10 or newer", vim.log.levels.ERROR)
  return false
end

--- Capture the last visual selection. Visual mode has already ended.
---@return string|nil
local function visual_text()
  local mode = vim.fn.visualmode()
  if mode == "" then
    return nil
  end
  local ok, lines = pcall(vim.fn.getregion, vim.fn.getpos("'<"), vim.fn.getpos("'>"), { type = mode })
  if not ok then
    vim.notify("Aski: " .. tostring(lines), vim.log.levels.ERROR)
    return nil
  end
  return table.concat(lines, "\n")
end

local function open_text(text)
  if text == nil then
    vim.notify("Aski: no selection", vim.log.levels.WARN)
    return
  end
  if vim.trim(text) == "" then
    vim.notify("Aski: selection is empty", vim.log.levels.WARN)
    return
  end
  local truncated = false
  if #text > MAX_CONTEXT then
    text = text:sub(1, MAX_CONTEXT)
    truncated = true
  end
  ui.open(text, {
    filetype = vim.bo.filetype,
    truncated = truncated,
  })
end

--- Ask about the last visual selection. Character and block selections are kept.
function M.ask_visual()
  if not nvim_ok() then
    return
  end
  open_text(visual_text())
end

--- Ask about a line range in the current buffer. Lines are 1-based and inclusive.
---@param line1 integer
---@param line2 integer
function M.ask_range(line1, line2)
  if not nvim_ok() then
    return
  end
  local lines = vim.api.nvim_buf_get_lines(0, line1 - 1, line2, false)
  open_text(table.concat(lines, "\n"))
end

--- Configure the client. `keymap = false` removes the default visual mapping.
---@param opts table|nil
function M.setup(opts)
  local options = vim.tbl_extend("force", {}, opts or {})
  local keymap = options.keymap
  options.keymap = nil
  config.setup(options)
  if keymap == false then
    pcall(vim.keymap.del, "x", "<leader>aq")
  elseif type(keymap) == "string" then
    vim.keymap.set("x", keymap, "<Plug>(AskiAsk)", {
      silent = true,
      desc = "Ask LLM about the selection",
    })
  end
end

return M
