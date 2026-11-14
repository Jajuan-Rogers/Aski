-- Headless demo init. Point Aski at the local mock, then open the plugin source.
local source = debug.getinfo(1, "S").source
local file = source:sub(1, 1) == "@" and source:sub(2) or source
local root = vim.fn.fnamemodify(file, ":h:h")

vim.g.mapleader = " "
vim.o.termguicolors = true
vim.o.number = true
vim.cmd("filetype plugin indent on")
vim.cmd("syntax enable")
vim.opt.runtimepath:prepend(root)
vim.cmd("runtime plugin/aski.lua")

local port = os.getenv("ASKI_DEMO_PORT") or "8765"
require("aski").setup({
  base_url = "http://127.0.0.1:" .. port .. "/v1",
  api_key = "demo",
  model = "echo-model",
  timeout_ms = 20000,
})

vim.cmd("edit " .. vim.fn.fnameescape(root .. "/lua/aski/client.lua"))
vim.cmd("normal! gg")
