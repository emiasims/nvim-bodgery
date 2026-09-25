local M = {}

--- @type table<string, bodging.ToolSpec>
local registered = {}

--- Registers or replaces a tool. It appears in the next `tools/list`.
--- @param name string
--- @param spec bodging.ToolSpec
function M.register(name, spec)
  registered[name] = spec
end

--- The built-in help and screen tools and every tool from `term`'s config and `register()`,
--- sorted by name. A user tool with a built-in's name replaces it. Handlers receive
--- `ctx = { session_id, bufnr }` for the calling terminal.
--- @param term bodging.Terminal
--- @return bodging.mcp.Tool[]
function M.list(term)
  local specs = vim.tbl_extend(
    'force',
    {},
    require('bodging.tools.help').tools,
    { nvim_screen = require('bodging.tools.screen').tool },
    term.config.tools,
    registered
  )
  local names = vim.tbl_keys(specs)
  table.sort(names)
  local out = {}
  for _, name in ipairs(names) do
    local spec = specs[name]
    out[#out + 1] = {
      name = name,
      description = spec.description,
      input_schema = spec.input_schema,
      --- @param term bodging.Terminal
      handler = function(args, term)
        return spec.handler(args, { session_id = term.session_id, bufnr = term.bufnr })
      end,
    }
  end
  return out
end

return M
