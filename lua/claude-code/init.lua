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

--- Sends the current visual selection to Claude, or the last one in this buffer.
function M.send_selection()
  M.harness.send_selection()
end

--- Mentions the current file in Claude's prompt, optionally with a line range.
--- @param range? integer[] first and last line, 1-based
function M.send_at_mention(range)
  M.harness.send_at_mention(range)
end

--- @class claude-code.SwitchOpts
--- @field new? boolean open a new terminal in the current window instead

--- Resumes session `id`: in place by typing the resume command into the active terminal,
--- or with `new` in a new terminal in the current window. A busy terminal is handled by
--- `opts.on_busy`.
--- @param bufnr? integer
--- @param id string
--- @param opts? claude-code.SwitchOpts
--- @overload fun(id: string, opts?: claude-code.SwitchOpts)
function M.switch(bufnr, id, opts)
  if type(bufnr) == 'string' then
    bufnr, id, opts = nil, bufnr, id --[[@as claude-code.SwitchOpts?]]
  end
  opts = opts or {}
  local terminal = require('claude-code.terminal')
  local resume = M.harness.resume(id)
  if opts.new then
    terminal.open({ args = resume.args })
    return
  end

  local term = terminal.active(bufnr)
  local actions = {
    interrupt = function()
      vim.fn.chansend(term.job, '\27')
      vim.defer_fn(function()
        terminal.submit(term, resume.keys)
      end, terminal.submit_delay)
    end,
    queue = function()
      vim.api.nvim_create_autocmd('User', {
        group = vim.api.nvim_create_augroup('claude-code', { clear = false }),
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
  elseif M.config.on_busy == 'error' then
    error('claude-code: Claude is busy in buffer ' .. term.bufnr, 0)
  elseif M.config.on_busy == 'prompt' then
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
    actions[M.config.on_busy]()
  end
end

--- Sessions newest first. Breaking out of the loop early skips reading the rest.
--- @param filter? claude-code.SessionFilter
--- @return fun(): claude-code.Session?
function M.sessions(filter)
  return M.harness.sessions(filter)
end

--- Files Claude read or edited in a session.
--- @param session_id string
--- @return string[]
function M.touched(session_id)
  return M.harness.touched(session_id)
end

--- Subagents and background tasks of a session.
--- @param session_id string
--- @return claude-code.Subtask[]
function M.subtasks(session_id)
  return M.harness.subtasks(session_id)
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
    vim.cmd.startinsert()
  end, { nargs = '*', desc = 'Start Claude in a split' })

  local mcp = require('claude-code.server.mcp')
  local terminal = require('claude-code.terminal')
  M.server = require('claude-code.server.http').start({ auth = terminal.lookup })
  M.server:route(
    mcp.http_route(mcp.new({ name = 'nvim', tools = require('claude-code.tools').list }), '/mcp')
  )
  M.harness.start(M.server)
  require('claude-code.restore').attach(group)
end

return M
