local M = {}

--- @type table<string, claude-code.ToolSpec>
local registered = {}

--- Registers or replaces a tool. It appears in the next `tools/list`.
--- @param name string
--- @param spec claude-code.ToolSpec
function M.register(name, spec)
  registered[name] = spec
end

--- Every tool from `opts.tools` and `register()`, sorted by name. Handlers receive
--- `ctx = { session_id, bufnr }` for the calling terminal.
--- @return claude-code.mcp.Tool[]
function M.list()
  local specs = vim.tbl_extend('force', {}, require('claude-code').config.tools, registered)
  local names = vim.tbl_keys(specs)
  table.sort(names)
  local out = {}
  for _, name in ipairs(names) do
    local spec = specs[name]
    out[#out + 1] = {
      name = name,
      description = spec.description,
      input_schema = spec.input_schema,
      --- @param term claude-code.Terminal
      handler = function(args, term)
        return spec.handler(args, { session_id = term.session_id, bufnr = term.bufnr })
      end,
    }
  end
  return out
end

return M
