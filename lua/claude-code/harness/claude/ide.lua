local diagnostics = require('claude-code.diagnostics')

local M = {}

local severity_names = { 'Error', 'Warning', 'Info', 'Hint' }

--- The `getDiagnostics` reply: a JSON list of `{ uri, diagnostics }` with LSP-style
--- 0-based ranges. `uri` is `file://` plus the raw path, the form Claude sends.
--- @param args { uri?: string }
--- @return table
local function get_diagnostics(args)
  local bufnr
  if args.uri then
    bufnr = diagnostics.loaded_buffer((args.uri:gsub('^file://', '')))
    if not bufnr then
      -- Claude asks before every edit, including files that were never opened
      return { content = { { type = 'text', text = '[]' } } }
    end
  end

  local files = {}
  for _, file in ipairs(diagnostics.collect(bufnr)) do
    local items = {}
    for _, d in ipairs(file.diagnostics) do
      items[#items + 1] = {
        message = d.message,
        severity = severity_names[d.severity] or 'Info',
        source = d.source,
        code = d.code and tostring(d.code) or nil,
        range = {
          start = { line = d.lnum, character = d.col },
          ['end'] = { line = d.end_lnum, character = d.end_col },
        },
      }
    end
    -- echo the requested uri: Claude drops a reply whose path differs from its request
    files[#files + 1] = { uri = args.uri or ('file://' .. file.path), diagnostics = items }
  end
  return { content = { { type = 'text', text = vim.json.encode(files) } } }
end

--- @param args { code: string }
--- @return table
local function execute_code(args)
  local chunk, err = load(args.code, '=executeCode')
  if not chunk then
    return { content = { { type = 'text', text = err } }, isError = true }
  end
  local res = vim.F.pack_len(pcall(chunk))
  if not res[1] then
    return { content = { { type = 'text', text = tostring(res[2]) } }, isError = true }
  end
  local parts = {}
  for i = 2, res.n do
    parts[#parts + 1] = vim.inspect(res[i])
  end
  return { content = { { type = 'text', text = #parts > 0 and table.concat(parts, '\n') or 'nil' } } }
end

--- Tools served on the IDE websocket.
--- @return claude-code.mcp.Tool[]
function M.tools()
  local tools = {
    {
      name = 'getDiagnostics',
      description = 'Get diagnostics (errors, warnings) from Neovim for a file, or for all loaded files',
      input_schema = {
        type = 'object',
        properties = { uri = { type = 'string', description = 'file:// URI; omit for all loaded files' } },
      },
      handler = get_diagnostics,
    },
  }
  if require('claude-code').config.execute_code then
    tools[#tools + 1] = {
      name = 'executeCode',
      description = "Run Lua in the user's Neovim and return the inspected return values",
      input_schema = {
        type = 'object',
        properties = {
          code = { type = 'string', description = 'Lua chunk; use return to get values back' },
        },
        required = { 'code' },
      },
      handler = execute_code,
    }
  end
  return tools
end

return M
