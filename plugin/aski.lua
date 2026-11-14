if vim.g.loaded_aski == 1 then
  return
end
vim.g.loaded_aski = 1

vim.keymap.set("x", "<Plug>(AskiAsk)", ":<C-u>lua require('aski').ask_visual()<CR>", {
  silent = true,
  desc = "Ask LLM about the selection",
})

if vim.g.aski_no_mappings ~= 1 then
  vim.keymap.set("x", "<leader>aq", "<Plug>(AskiAsk)", {
    silent = true,
    desc = "Ask LLM about the selection",
  })
end

vim.api.nvim_create_user_command("Aski", function(opts)
  require("aski").ask_range(opts.line1, opts.line2)
end, {
  range = true,
  desc = "Ask an LLM about the given lines",
})
