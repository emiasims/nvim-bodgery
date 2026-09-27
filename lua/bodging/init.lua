--- @class bodging
local M = vim._defer_require('bodging', {
  config = ..., --- @module 'bodging.config'
  editor = ..., --- @module 'bodging.editor'
  restore = ..., --- @module 'bodging.restore'
  terminal = ..., --- @module 'bodging.terminal'
  tools = ..., --- @module 'bodging.tools'
})

M.harnesses = vim._defer_require('bodging.harness', {
  claude = ..., --- @module 'bodging.harness.claude'
})

--- @type table<string, table> options from `setup()` by config name
local options = {}

--- Configs by name, validated on first read.
--- @type table<string, bodging.Config>
M.configs = setmetatable({}, {
  __index = function(configs, name)
    if not options[name] then
      error(('bodging: no config named %s, call setup() first'):format(name), 0)
    end
    configs[name] = M.config.resolve(options[name])
    return rawget(configs, name)
  end,
})

--- @type bodging.http.Server?
M.server = nil

--- @type table<string, true> harnesses running on `M.server`
local started = {}

--- Starts the server and `harness` on it unless they are running.
--- @param harness string
--- @return bodging.http.Server
function M.start(harness)
  if not M.server then
    local mcp = require('bodging.server.mcp')
    M.server = require('bodging.server.http').start({ auth = M.terminal.lookup })
    M.server:route(mcp.http_route(mcp.new({ name = 'nvim', tools = M.tools.list }), '/mcp'))
    M.editor.register(M.server)
  end
  if not started[harness] then
    M.harnesses[harness].start(M.server)
    started[harness] = true
  end
  return M.server
end

--- Stops the server and every harness on it. The next terminal starts them again.
function M.stop()
  for harness in pairs(started) do
    M.harnesses[harness].stop()
  end
  started = {}
  if M.server then
    M.server:stop()
    M.server = nil
  end
end

--- @param config? bodging.ConfigArg
--- @return bodging.Config?
local function get(config)
  return config and M.config.get(config)
end

--- Starts an agent in a terminal and returns its buffer.
--- @param config bodging.ConfigArg
--- @param opts? bodging.OpenOpts
--- @return integer bufnr
function M.open(config, opts)
  return M.terminal.open(M.config.get(config), opts)
end

--- Hides the target terminal where it shows in the current tab, and otherwise shows it in
--- the window `show.window` picks. The current window's terminal is always the target,
--- and without one `config.active` picks it.
--- @param bufnr? integer
--- @param config? bodging.ConfigArg
function M.toggle(bufnr, config)
  local c = get(config)
  M.terminal.target(bufnr, c, function(term)
    local win = term and M.terminal.shown(term.bufnr)
    if win then
      M.terminal.hide(win)
    else
      M.terminal.show(term, c)
    end
  end)
end

--- Resumes session `id` in the target terminal, or in a new terminal when `config.active`
--- reaches `new`.
--- @param id string
--- @param bufnr? integer
--- @param config? bodging.ConfigArg
function M.resume(id, bufnr, config)
  local c = get(config)
  M.terminal.target(bufnr, c, function(term)
    if term then
      term.harness.resume(term, id)
    elseif not c then
      error('bodging: pass a config to resume in a new terminal', 0)
    else
      M.terminal.open(c, { args = M.harnesses[c.harness].resume_args(id) })
    end
  end)
end

--- @param bufnr? integer
--- @param config? bodging.Config
--- @param fn fun(term: bodging.Terminal)
local function existing(bufnr, config, fn)
  M.terminal.target(bufnr, config, function(term)
    fn(term or error('bodging: no agent terminal to send to', 0))
  end)
end

--- Sends the current visual selection to the target terminal, or the last one in this
--- buffer.
--- @param bufnr? integer
--- @param config? bodging.ConfigArg
function M.send_selection(bufnr, config)
  existing(bufnr, get(config), function(term)
    term.harness.send_selection()
  end)
end

--- Mentions the current file in the target terminal's prompt, optionally with a line
--- range.
--- @param range? integer[] first and last line, 1-based
--- @param bufnr? integer
--- @param config? bodging.ConfigArg
function M.send_at_mention(range, bufnr, config)
  existing(bufnr, get(config), function(term)
    term.harness.send_at_mention(range)
  end)
end

--- Registers or replaces a custom MCP tool, shown to Claude as `mcp__nvim__<name>`.
--- @param name string
--- @param spec bodging.ToolSpec
function M.tool(name, spec)
  M.tools.register(name, spec)
end

--- Iterates over the sessions of `config`'s harness, newest first. Breaking out of the
--- loop early skips reading the rest.
--- @param config bodging.ConfigArg
--- @param filter? bodging.SessionFilter
--- @return fun(): bodging.Session?
function M.sessions(config, filter)
  local c = M.config.get(config)
  return M.harnesses[c.harness].sessions(filter, c)
end

--- Files the agent read or edited in a session.
--- @param session_id string
--- @param config bodging.ConfigArg
--- @return string[]
function M.touched(session_id, config)
  return M.harnesses[M.config.get(config).harness].touched(session_id)
end

--- Subagents and background tasks of a session.
--- @param session_id string
--- @param config bodging.ConfigArg
--- @return bodging.Subtask[]
function M.subtasks(session_id, config)
  return M.harnesses[M.config.get(config).harness].subtasks(session_id)
end

--- @type table<string, string[]> config names by user command, the command's default first
local commands = {}

--- Removes config `name` from every command but `keep`, and deletes commands left without
--- a config.
--- @param name string
--- @param keep? string
local function unregister_command(name, keep)
  for command, names in pairs(commands) do
    if command ~= keep and vim.list_contains(names, name) then
      table.remove(names, vim.fn.index(names, name) + 1)
      if #names == 0 then
        commands[command] = nil
        vim.api.nvim_del_user_command(command)
      end
    end
  end
end

--- Points user command `command` at config `name`, and deletes commands no config uses.
--- @param command string
--- @param name string
local function register_command(command, name)
  unregister_command(name, command)
  local names = commands[command] or {}
  commands[command] = names
  if not vim.list_contains(names, name) then
    names[#names + 1] = name
  end

  vim.api.nvim_create_user_command(command, function(ev)
    local args, config = ev.fargs, names[1]
    if args[1] and vim.list_contains(names, args[1]) then
      config = table.remove(args, 1)
    end
    M.open(config, { args = args, mods = ev.smods })
  end, {
    nargs = '*',
    complete = function(lead)
      return vim.tbl_filter(function(n)
        return vim.startswith(n, lead)
      end, names)
    end,
    desc = 'Start an agent in a split, optionally naming the config',
  })
end

--- @type table<string, true> names of configs `detect()` created
local detected = {}

--- @param opts table
local function add(opts)
  local harness = opts.harness or 'claude'
  local name = opts.name or harness
  local command = opts.command or harness:gsub('^%l', string.upper)
  if type(command) ~= 'string' or not command:match('^%u%w*$') then
    error(
      ('bodging: command: expected a name starting with an uppercase letter, got %s'):format(command),
      0
    )
  end
  options[name] = vim.tbl_extend('force', {}, opts, { name = name, command = command, harness = harness })
  rawset(M.configs, name, nil)
  register_command(command, name)
end

--- Creates or replaces the config named `opts.name`, and removes the config `detect()`
--- created for its harness. Options are validated on first read, and the server starts
--- with the first terminal.
--- @param opts? table see |bodging.Config|
function M.setup(opts)
  vim.validate('opts', opts, 'table', true)
  opts = opts or {}
  local harness = opts.harness or 'claude'
  for name in pairs(detected) do
    if options[name].harness == harness then
      detected[name], options[name] = nil, nil
      rawset(M.configs, name, nil)
      unregister_command(name)
    end
  end
  add(opts)
end

--- Creates a default config for each harness whose `detect()` finds it installed, unless
--- `setup()` already made one for that harness.
function M.detect()
  local configured = {}
  for _, o in pairs(options) do
    configured[o.harness] = true
  end
  for harness in pairs(M.harnesses._submodules) do
    if not configured[harness] and require(('bodging.harness.%s.config'):format(harness)).detect() then
      add({ harness = harness })
      detected[harness] = true
    end
  end
end

return M
