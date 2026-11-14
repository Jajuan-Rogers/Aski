-- Test harness init. Sets the leader before the plugin file creates mappings.
local source = debug.getinfo(1, "S").source
local file = source:sub(1, 1) == "@" and source:sub(2) or source
local root = vim.fn.fnamemodify(file, ":h:h")

vim.g.mapleader = " "
vim.o.swapfile = false
vim.o.undofile = false
vim.o.hidden = true
vim.o.more = false
vim.o.shortmess = "FWIc"
pcall(function()
  vim.o.columns = 100
  vim.o.lines = 40
end)

vim.opt.runtimepath:prepend(root)
vim.cmd("runtime plugin/aski.lua")
