# Aski

Aski is a Neovim plugin for asking an LLM about text you have selected. Highlight a block or a line, press `<leader>aq`, type a question, and press Enter. The answer streams into the same buffer.

It is Lua, with no plugin dependencies. [curl](https://curl.se/) performs the HTTP request.

## Requirements

- Neovim 0.10 or newer
- curl

## Install

lazy.nvim:

```lua
{
  "Jajuan-Rogers/Aski",
  config = function()
    require("aski").setup()
  end,
}
```

Without a plugin manager, add this repository to `'runtimepath'`.

## Use

1. Visually select text (`v`, `V`, or Ctrl-V).
2. Press `<leader>aq`.
3. Type a question under the selection.
4. Press Enter.

The selection stays at the top. The answer is markdown under `### Answer`. `q` closes the buffer. Ctrl-C cancels an in-flight request. Edit the question and press Enter to ask again.

`:Aski` asks about the current line. `:'<,'>Aski` asks about a line range. The visual mapping keeps a character-wise or block selection.

Set `vim.g.aski_no_mappings = 1` before the plugin loads to skip `<leader>aq`, then map `<Plug>(AskiAsk)` yourself. `require("aski").setup({ keymap = false })` removes the default mapping later.

## Configure

```lua
require("aski").setup({
  model = "gpt-4o-mini",
  base_url = "https://api.openai.com/v1", -- "{base_url}/chat/completions"
  api_key = "", -- or leave empty and use an environment variable
  max_tokens = 1024,
  timeout_ms = 120000,
  keymap = "<leader>aq",
})
```

Environment variables fill any option you did not pass to `setup()`:

| Variable | Purpose |
| --- | --- |
| `ASKI_API_KEY` | API key |
| `OPENAI_API_KEY` | Used when `ASKI_API_KEY` is unset |
| `ASKI_BASE_URL` | OpenAI-compatible base URL, including `/v1` |
| `ASKI_MODEL` | Model name |

The official OpenAI host refuses to send a request until a key is set. Any other base URL is called as-is, so a local server can omit the key:

```lua
require("aski").setup({
  base_url = "http://127.0.0.1:11434/v1",
  model = "llama3.2",
  api_key = "",
})
```

## Behavior

- The plugin file only defines a command and a mapping. Lua modules load on first use.
- curl runs asynchronously and streams server-sent events. A plain JSON body is accepted too.
- Chunks that arrive in the same event-loop turn are inserted with one buffer update.
- The API key is passed in a `0600` header file, not on the curl command line.

The selected text is sent to `base_url`.

## Development

Neovim, curl, and Python 3 are enough to run the tests. `scripts/cloud-agent-install.sh` installs them on Ubuntu.

```bash
make test
```

`:help aski` covers the same workflow.
