local uv = vim.uv

local M = {}

M.TOKEN_ENV = 'BODGING_TOKEN'

local root = vim.fs.normalize(debug.getinfo(1, 'S').source:sub(2)):match('^(.*)/lua/bodging/')

M.editor = vim.fs.joinpath(
  root,
  'bin',
  vim.fn.has('win32') == 1 and 'bodging-editor.cmd' or 'bodging-editor'
)

--- Claude's config directory: `$CLAUDE_CONFIG_DIR`, else `~/.claude`.
--- @return string
function M.config_dir()
  local dir = vim.env.CLAUDE_CONFIG_DIR
  return dir and dir ~= '' and vim.fs.normalize(dir) or vim.fs.normalize('~/.claude')
end

--- Writes `data` to `path` through a temporary file and a rename, with mode 0600.
--- @param path string
--- @param data string
function M.write_private(path, data)
  vim.fn.mkdir(vim.fs.dirname(path), 'p', '0700')
  local tmp = ('%s.tmp.%d.%d'):format(path, uv.os_getpid(), uv.hrtime())
  local fd = assert(uv.fs_open(tmp, 'w', tonumber('600', 8)))
  local ok, err = uv.fs_write(fd, data)
  uv.fs_close(fd)
  if not ok then
    uv.fs_unlink(tmp)
    error(err)
  end
  assert(uv.fs_rename(tmp, path))
end

local TOOL_MATCHER = 'Read|Edit|Write|NotebookEdit|Bash'

--- @param port integer
--- @return table settings Claude settings registering the plugin's hooks
function M.settings(port)
  local hooks = {}
  for _, event in ipairs(require('bodging.config').hook_events) do
    local hook
    if event == 'SessionStart' then
      -- Claude skips HTTP hooks for SessionStart, so pipe the input to the same endpoint
      hook = {
        type = 'command',
        command = (
          [[curl -sS --noproxy '*' --max-time 10 -X POST -H 'Content-Type: application/json' ]]
          .. [[-H "Authorization: Bearer $%s" --data-binary @- 'http://127.0.0.1:%d/hooks/SessionStart']]
        ):format(M.TOKEN_ENV, port),
      }
    else
      hook = {
        type = 'http',
        url = ('http://127.0.0.1:%d/hooks/%s'):format(port, event),
        headers = { Authorization = 'Bearer $' .. M.TOKEN_ENV },
        allowedEnvVars = { M.TOKEN_ENV },
      }
    end
    local matcher = (event == 'PreToolUse' or event == 'PostToolUse') and TOOL_MATCHER or nil
    hooks[event] = { { matcher = matcher, hooks = { hook } } }
  end
  return { hooks = hooks }
end

--- @param port integer
--- @return table config MCP config for the plugin's `/mcp` endpoint
function M.mcp_config(port)
  return {
    mcpServers = {
      nvim = {
        type = 'http',
        url = ('http://127.0.0.1:%d/mcp'):format(port),
        headers = { Authorization = ('Bearer ${%s}'):format(M.TOKEN_ENV) },
      },
    },
  }
end

--- Adds `127.0.0.1` and `localhost` to a comma-separated `no_proxy` value once each.
--- @param value? string
--- @return string
function M.no_proxy(value)
  local hosts = {}
  for host in (value or ''):gmatch('[^,%s]+') do
    hosts[#hosts + 1] = host
  end
  for _, host in ipairs({ '127.0.0.1', 'localhost' }) do
    if not vim.list_contains(hosts, host) then
      hosts[#hosts + 1] = host
    end
  end
  return table.concat(hosts, ',')
end

--- @class bodging.claude.LaunchOpts
--- @field cmd string[] the user's command and default flags
--- @field args? string[] extra arguments for this terminal
--- @field port integer
--- @field token string
--- @field settings string path of the settings file
--- @field mcp_config string path of the MCP config file

--- @param opts bodging.claude.LaunchOpts
--- @return { cmd: string[], env: table<string, string> }
function M.build(opts)
  local cmd = vim.list_extend({}, opts.cmd)
  -- --mcp-config takes several values, so --settings follows it to end the list
  vim.list_extend(cmd, { '--mcp-config', opts.mcp_config, '--settings', opts.settings })
  vim.list_extend(cmd, opts.args or {})

  return {
    cmd = cmd,
    env = {
      CLAUDE_CODE_SSE_PORT = tostring(opts.port),
      [M.TOKEN_ENV] = opts.token,
      EDITOR = M.editor,
      FORCE_CODE_TERMINAL = 'true',
      no_proxy = M.no_proxy(vim.env.no_proxy),
      NO_PROXY = M.no_proxy(vim.env.NO_PROXY),
    },
  }
end

return M
