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

--- Name of the config used where no terminal picks one: the first `setup()` call's.
--- @type string?
M.default = nil

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

--- The default config's harness.
local function harness()
  return M.harnesses[M.configs[M.default].harness]
end

--- Starts Claude in a terminal and returns its buffer.
--- @param opts? bodging.OpenOpts
--- @return integer bufnr
function M.open(opts)
  return M.terminal.open(opts)
end

--- Registers or replaces a custom MCP tool, shown to Claude as `mcp__nvim__<name>`.
--- @param name string
--- @param spec bodging.ToolSpec
function M.tool(name, spec)
  M.tools.register(name, spec)
end

--- Sends the current visual selection to Claude, or the last one in this buffer.
function M.send_selection()
  harness().send_selection()
end

--- Mentions the current file in Claude's prompt, optionally with a line range.
--- @param range? integer[] first and last line, 1-based
function M.send_at_mention(range)
  harness().send_at_mention(range)
end

--- @class bodging.SwitchOpts
--- @field new? boolean open a new terminal in the current window instead

--- Resumes session `id`: in place by typing the resume command into the active terminal,
--- or with `new` in a new terminal in the current window. A busy terminal is handled by
--- `opts.on_busy`.
--- @param bufnr? integer
--- @param id string
--- @param opts? bodging.SwitchOpts
--- @overload fun(id: string, opts?: bodging.SwitchOpts)
function M.switch(bufnr, id, opts)
  if type(bufnr) == 'string' then
    bufnr, id, opts = nil, bufnr, id --[[@as bodging.SwitchOpts?]]
  end
  opts = opts or {}
  local terminal = M.terminal
  if opts.new then
    terminal.open({ args = harness().resume(id).args })
    return
  end

  local term = terminal.active(bufnr)
  local resume = term.harness.resume(id)
  local actions = {
    interrupt = function()
      vim.fn.chansend(term.job, '\27')
      vim.defer_fn(function()
        terminal.submit(term, resume.keys)
      end, terminal.submit_delay)
    end,
    queue = function()
      vim.api.nvim_create_autocmd('User', {
        group = vim.api.nvim_create_augroup('bodging', { clear = false }),
        pattern = 'ClaudeStatusChanged',
        callback = function(ev)
          if ev.data.bufnr == term.bufnr and ev.data.status == 'idle' then
            terminal.submit(term, resume.keys)
            return true
          end
        end,
      })
    end,
  }

  -- typing into a permission prompt would answer it, so waiting counts as busy
  if term.status ~= 'busy' and term.status ~= 'waiting' then
    terminal.submit(term, resume.keys)
  elseif term.config.on_busy == 'error' then
    error('bodging: Claude is busy in buffer ' .. term.bufnr, 0)
  elseif term.config.on_busy == 'prompt' then
    vim.ui.select({ 'interrupt', 'queue' }, {
      prompt = 'Claude is busy',
      format_item = function(item)
        return item == 'interrupt' and 'Interrupt and resume now' or 'Resume when idle'
      end,
    }, function(choice)
      if choice then
        actions[choice]()
      end
    end)
  else
    actions[term.config.on_busy]()
  end
end

--- Sessions newest first. Breaking out of the loop early skips reading the rest.
--- @param filter? bodging.SessionFilter
--- @return fun(): bodging.Session?
function M.sessions(filter)
  return harness().sessions(filter)
end

--- Files Claude read or edited in a session.
--- @param session_id string
--- @return string[]
function M.touched(session_id)
  return harness().touched(session_id)
end

--- Subagents and background tasks of a session.
--- @param session_id string
--- @return bodging.Subtask[]
function M.subtasks(session_id)
  return harness().subtasks(session_id)
end

--- @type table<string, string[]> config names by user command, the command's default first
local commands = {}

--- Points user command `command` at config `name`, and deletes commands no config uses.
--- @param command string
--- @param name string
local function register_command(command, name)
  for other, names in pairs(commands) do
    if other ~= command and vim.list_contains(names, name) then
      table.remove(names, vim.fn.index(names, name) + 1)
      if #names == 0 then
        commands[other] = nil
        vim.api.nvim_del_user_command(other)
      end
    end
  end
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
    M.open({ config = config, args = args, mods = ev.smods })
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

--- Creates or replaces the config named `opts.name`. Options are validated on first read,
--- and the server starts with the first terminal.
--- @param opts? table see |bodging.Config|
function M.setup(opts)
  vim.validate('opts', opts, 'table', true)
  opts = opts or {}
  local harness = opts.harness or 'claude'
  local name = opts.name or harness
  local command = opts.command or harness:gsub('^%l', string.upper)
  if type(command) ~= 'string' or not command:match('^%u%w*$') then
    error(
      ('bodging: command: expected a name starting with an uppercase letter, got %s'):format(command),
      0
    )
  end
  options[name] = vim.tbl_extend('force', {}, opts, { name = name, command = command })
  rawset(M.configs, name, nil)
  M.default = M.default or name
  register_command(command, name)

  local group = vim.api.nvim_create_augroup('bodging', { clear = true })
  vim.api.nvim_create_autocmd('VimLeavePre', {
    group = group,
    desc = 'Stop the bodging server and remove its lockfile',
    callback = M.stop,
  })

  vim.api.nvim_create_autocmd('SessionWritePost', {
    group = group,
    desc = 'Record Claude terminals for session restore',
    callback = function()
      M.restore.save()
    end,
  })
  vim.api.nvim_create_autocmd('BufNew', {
    group = group,
    pattern = 'term://*',
    desc = 'Mark restored Claude terminals for relaunch',
    callback = function(ev)
      M.restore.on_new(ev)
    end,
  })
  vim.api.nvim_create_autocmd('BufReadCmd', {
    group = group,
    pattern = 'term://*',
    nested = true,
    desc = 'Relaunch a restored Claude terminal',
    callback = function(ev)
      M.restore.on_read(ev)
    end,
  })
end

return M
