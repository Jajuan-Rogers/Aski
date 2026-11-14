--- Option resolution. Environment variables fill anything setup() did not set.

local M = {}

local DEFAULT_SYSTEM_PROMPT = table.concat({
  "You answer questions about text the user selected in Neovim.",
  "Be accurate and concise.",
  "Use markdown when it makes the answer easier to read.",
}, " ")

local defaults = {
  model = "gpt-4o-mini",
  base_url = "https://api.openai.com/v1",
  api_key = "",
  system_prompt = DEFAULT_SYSTEM_PROMPT,
  max_tokens = 1024,
  timeout_ms = 120000,
}

local current = {}
for key, value in pairs(defaults) do
  current[key] = value
end

local user_set = {}

local function known(key)
  return defaults[key] ~= nil
end

--- Record user options. Unknown keys are rejected so typos fail immediately.
---@param opts table|nil
function M.setup(opts)
  for key, value in pairs(opts or {}) do
    if not known(key) then
      error("Aski: unknown option '" .. tostring(key) .. "'")
    end
    user_set[key] = true
    current[key] = value
  end
end

local function nonempty(value)
  return type(value) == "string" and value ~= ""
end

--- Resolved request settings. Call this at request time, not at startup.
---@return table
function M.resolve()
  local resolved = {}
  for key, value in pairs(current) do
    resolved[key] = value
  end
  if not user_set.model and nonempty(vim.env.ASKI_MODEL) then
    resolved.model = vim.env.ASKI_MODEL
  end
  if not user_set.base_url and nonempty(vim.env.ASKI_BASE_URL) then
    resolved.base_url = vim.env.ASKI_BASE_URL
  end
  if not user_set.api_key then
    if nonempty(vim.env.ASKI_API_KEY) then
      resolved.api_key = vim.env.ASKI_API_KEY
    elseif nonempty(vim.env.OPENAI_API_KEY) then
      resolved.api_key = vim.env.OPENAI_API_KEY
    end
  end
  local base = resolved.base_url
  if type(base) ~= "string" or base == "" then
    base = defaults.base_url
  end
  resolved.base_url = base:gsub("/+$", "")
  return resolved
end

return M
