local hooks = require('bodgery.harness.claude.hooks')
local ide = require('bodgery.harness.claude.ide')
local launch = require('bodgery.harness.claude.launch')
local mcp = require('bodgery.server.mcp')
local sessions = require('bodgery.harness.claude.sessions')
local ws = require('bodgery.server.ws')

local M = {}

M.capabilities = { ide = true, resume_in_place = true }

--- Typed before text when `on_busy` is `interrupt`.
M.interrupt = '\27'

M.on_hook = hooks.on_hook
M.send_selection = ide.send_selection
M.send_at_mention = ide.send_at_mention
M.sessions = sessions.sessions
M.live = sessions.live

--- Types the resume command for session `id` into `term`.
--- @param term bodgery.Terminal
--- @param id string
function M.resume(term, id)
  require('bodgery.terminal').submit(term, '/resume ' .. id)
end

--- Arguments that start a terminal in session `id`.
--- @param id string
--- @return string[]
function M.resume_args(id)
  return { '--resume', id }
end

--- Files from the transcript, then files hooks reported that it doesn't hold yet.
--- @param id string
--- @return string[]
function M.touched(id)
  local out = sessions.touched(id)
  for _, path in ipairs((hooks.sessions[id] or {}).touched or {}) do
    if not vim.list_contains(out, path) then
      out[#out + 1] = path
    end
  end
  return out
end

--- Subtasks from the transcript, with hooks deciding which are open.
--- @param id string
--- @return bodgery.Subtask[]
function M.subtasks(id)
  local out = sessions.subtasks(id)
  local live = vim.deepcopy((hooks.sessions[id] or {}).subtasks or {})
  for _, subtask in ipairs(out) do
    local hooked = live[subtask.id]
    if hooked then
      subtask.open = hooked.open
      live[subtask.id] = nil
    end
  end
  local rest = vim.tbl_values(live)
  table.sort(rest, function(a, b)
    return a.id < b.id
  end)
  return vim.list_extend(out, rest)
end

--- @class bodgery.claude.State
--- @field port integer
--- @field dir string holds the settings and MCP config files
--- @field lockfile string
--- @field auth_token string shared by every websocket connection

--- @type bodgery.claude.State?
M.state = nil

--- @return string
local function random_token()
  return vim.text.hexencode(assert(vim.uv.random(16)))
end

--- Writes the launch files and the lockfile, and serves the IDE websocket on `server`.
--- @param server bodgery.http.Server
function M.start(server)
  local port = server.port
  local dir = vim.fs.joinpath(vim.fn.stdpath('run'), 'bodgery', tostring(port))
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

  local handlers = mcp.ws_handlers(mcp.new({ name = 'nvim-ide', tools = ide.tools }))
  server:route(ws.route({
    path = '/',
    token = function()
      return state.auth_token
    end,
    on_open = function(conn)
      ide.clients[conn] = true
      handlers.on_open(conn)
    end,
    on_message = handlers.on_message,
    on_close = function(conn)
      ide.clients[conn] = nil
      handlers.on_close(conn)
    end,
  }))
  ide.attach(vim.api.nvim_create_augroup('bodgery.ide', { clear = true }))
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
  local state = assert(M.state, 'bodgery: the server is not running')
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
