# Aski

Aski asks an LLM about text you have selected in Neovim. Highlight a block or a line, press the mapping, type a question, and press Enter. The answer streams into the same buffer.

It is Lua, with no plugin dependencies. [curl](https://curl.se/) performs the HTTP request.

## Requirements

- Neovim 0.10 or newer
- `curl` on your `PATH`
- An API key for an OpenAI-compatible server, or a local server such as Ollama

## NvChad

NvChad keeps your plugins in the starter config, separate from NvChad itself. That directory is usually `~/.config/nvim`. Leader is Space.

### 1. Add the plugin

Create `lua/plugins/aski.lua` inside your NvChad config:

```lua
return {
  {
    "Jajuan-Rogers/Aski",
    cmd = "Aski",
    keys = {
      {
        "<leader>aq",
        "<Plug>(AskiAsk)",
        mode = "x",
        desc = "Ask about selection",
      },
    },
    init = function()
      -- Leave the mapping to the keys entry above.
      vim.g.aski_no_mappings = 1
    end,
    config = function()
      require("aski").setup({
        model = "gpt-4o-mini",
      })
    end,
  },
}
```

Any file under `lua/plugins/` is picked up. If you already keep plugins in `lua/plugins/init.lua`, paste the inner table into the list that file returns.

lazy.nvim loads Aski the first time you press the mapping or run `:Aski`. which-key shows "Ask about selection" after Space in visual mode.

### 2. Set the API key

Export the key from the shell that starts Neovim. Keep it out of the plugin file.

```bash
export ASKI_API_KEY="sk-..."
```

`OPENAI_API_KEY` is used when `ASKI_API_KEY` is unset.

A local Ollama server needs no key. Put this in `config` instead:

```lua
require("aski").setup({
  base_url = "http://127.0.0.1:11434/v1",
  model = "llama3.2",
  api_key = "",
})
```

### 3. Install

Open Neovim and run:

```vim
:Lazy sync
```

Restart Neovim after the install finishes. Confirm curl is visible to Neovim with `:!curl --version`.

### 4. Ask

1. Visually select text with `v`, `V`, or Ctrl-V.
2. Press Space `aq`.
3. Type a question under the selection and press Enter.

The selection stays at the top. The answer is markdown under `### Answer`.

- `q` closes the window.
- Ctrl-C cancels a request that is still running.
- Edit the question and press Enter to ask again.
- `:Aski` asks about the current line. `:'<,'>Aski` asks about a line range.

`:help aski` covers the same commands.

## Other installs

lazy.nvim outside NvChad:

```lua
{
  "Jajuan-Rogers/Aski",
  config = function()
    require("aski").setup()
  end,
}
```

That spec uses Aski's built-in visual mapping, `<leader>aq`. Load it after `mapleader` is set.

Without a plugin manager, add this repository to `'runtimepath'`.

## Configure

`setup()` overrides the defaults. Anything you leave unset can come from the environment.

```lua
require("aski").setup({
  model = "gpt-4o-mini",
  base_url = "https://api.openai.com/v1", -- requests go to {base_url}/chat/completions
  api_key = "",
  max_tokens = 1024,
  timeout_ms = 120000,
  keymap = "<leader>aq", -- false removes the built-in mapping
})
```

| Variable | Purpose |
| --- | --- |
| `ASKI_API_KEY` | API key |
| `OPENAI_API_KEY` | Used when `ASKI_API_KEY` is unset |
| `ASKI_BASE_URL` | OpenAI-compatible base URL, including `/v1` |
| `ASKI_MODEL` | Model name |

The official OpenAI host waits for a key before it sends a request. Any other base URL is called as given, so a local server can use an empty `api_key`.

The selected text is sent to `base_url`.

## Behavior

- The plugin file defines a command and a mapping. Lua modules load on first use.
- curl runs asynchronously and streams server-sent events. A plain JSON body is accepted too.
- Chunks that arrive in the same event-loop turn are inserted with one buffer update.
- The API key is passed in a `0600` header file, not on the curl command line.

## Development

Neovim, curl, and Python 3 are enough to run the tests. `scripts/cloud-agent-install.sh` installs them on Ubuntu.

```bash
make test
```
