local M = {}

--- @type claude-code.Config?
M.config = nil

--- @type claude-code.http.Server?
M.server = nil

M.harness = require('claude-code.harness.claude')

--- Stops the server and removes the lockfile. `setup()` starts them again.
function M.stop()
  M.harness.stop()
  if M.server then
    M.server:stop()
    M.server = nil
  end
end

--- Starts Claude in a terminal and returns its buffer.
--- @param opts? claude-code.OpenOpts
--- @return integer bufnr
function M.open(opts)
  return require('claude-code.terminal').open(opts)
end

--- Registers or replaces a custom MCP tool, shown to Claude as `mcp__nvim__<name>`.
--- @param name string
--- @param spec claude-code.ToolSpec
function M.tool(name, spec)
  require('claude-code.tools').register(name, spec)
end

--- Files Claude read or edited in a session.
--- @param session_id string
--- @return string[]
function M.touched(session_id)
  local live = require('claude-code.harness.claude.hooks').sessions[session_id]
  return live and vim.deepcopy(live.touched) or {}
end

--- Subagents and background tasks of a session.
--- @param session_id string
--- @return claude-code.Subtask[]
function M.subtasks(session_id)
  local live = require('claude-code.harness.claude.hooks').sessions[session_id]
  return live and vim.tbl_values(vim.deepcopy(live.subtasks)) or {}
end

--- Configures the plugin and starts the server. Calling it again replaces the previous
--- configuration and server.
--- @param opts? table see |claude-code.Config|
function M.setup(opts)
  -- validate first so a bad call leaves the running configuration intact
  local config = require('claude-code.config').resolve(opts)
  M.stop()
  M.config = config

  local group = vim.api.nvim_create_augroup('claude-code', { clear = true })
  vim.api.nvim_create_autocmd('VimLeavePre', { group = group, callback = M.stop })

  vim.api.nvim_create_user_command('Claude', function(ev)
    M.open({ args = ev.fargs, mods = ev.smods })
  end, { nargs = '*', desc = 'Start Claude in a split' })

  local mcp = require('claude-code.server.mcp')
  local terminal = require('claude-code.terminal')
  M.server = require('claude-code.server.http').start({ auth = terminal.lookup })
  M.server:route(
    mcp.http_route(mcp.new({ name = 'nvim', tools = require('claude-code.tools').list }), '/mcp')
  )
  M.harness.start(M.server)
end

return M
