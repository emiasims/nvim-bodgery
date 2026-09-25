local hooks = require('claude-code.harness.claude.hooks')
local launch = require('claude-code.harness.claude.launch')
local mcp = require('claude-code.server.mcp')
local ws = require('claude-code.server.ws')

local M = {}

M.capabilities = { ide = true, resume_in_place = true }

M.on_hook = hooks.on_hook

--- @class claude-code.claude.State
--- @field port integer
--- @field dir string holds the settings and MCP config files
--- @field lockfile string
--- @field auth_token string shared by every websocket connection

--- @type claude-code.claude.State?
M.state = nil

--- @return string
local function random_token()
  return vim.text.hexencode(assert(vim.uv.random(16)))
end

--- Writes the launch files and the lockfile, and serves the IDE websocket on `server`.
--- @param server claude-code.http.Server
function M.start(server)
  local port = server.port
  local dir = vim.fs.joinpath(vim.fn.stdpath('run'), 'claude-code', tostring(port))
  local state = {
    port = port,
    dir = dir,
    lockfile = vim.fs.joinpath(launch.config_dir(), 'ide', port .. '.lock'),
    auth_token = random_token(),
  }
  M.state = state

  launch.write_private(vim.fs.joinpath(dir, 'settings.json'), vim.json.encode(launch.settings(port)))
  launch.write_private(vim.fs.joinpath(dir, 'mcp.json'), vim.json.encode(launch.mcp_config(port)))
  launch.write_private(
    state.lockfile,
    vim.json.encode({
      pid = vim.fn.getpid(),
      workspaceFolders = { vim.fn.getcwd() },
      ideName = 'Neovim',
      transport = 'ws',
      authToken = state.auth_token,
    })
  )

  hooks.register(server)

  local ide = mcp.new({
    name = 'nvim-ide',
    tools = function()
      return {}
    end,
  })
  server:route(ws.route(vim.tbl_extend('force', mcp.ws_handlers(ide), {
    path = '/',
    token = function()
      return state.auth_token
    end,
  })))
end

--- Removes the lockfile and the launch files.
function M.stop()
  local state = M.state
  if not state then
    return
  end
  M.state = nil
  vim.uv.fs_unlink(state.lockfile)
  vim.fn.delete(state.dir, 'rf')
end

--- @param opts { cmd: string[], args?: string[], token: string }
--- @return { cmd: string[], env: table<string, string> }
function M.launch(opts)
  local state = assert(M.state, 'claude-code: the server is not running')
  return launch.build({
    cmd = opts.cmd,
    args = opts.args,
    port = state.port,
    token = opts.token,
    settings = vim.fs.joinpath(state.dir, 'settings.json'),
    mcp_config = vim.fs.joinpath(state.dir, 'mcp.json'),
  })
end

return M
