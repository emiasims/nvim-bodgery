local helpers = require('test.helpers')
local exec_lua = require('nvim-test.helpers').exec_lua

describe('hooks', function()
  before_each(function()
    helpers.clear()
    exec_lua(function()
      _G.h = require('test.helpers')
      _G.before = h.handles()
      _G.cc = require('bodgery')
      _G.notifications = {}
      vim.notify = function(msg)
        notifications[#notifications + 1] = msg
      end
      cc.setup({
        cmd = h.fake_cmd(),
        hooks = {
          PreToolUse = function(input)
            if input.tool_name == 'Write' then
              return {
                hookSpecificOutput = {
                  hookEventName = 'PreToolUse',
                  permissionDecision = 'deny',
                  permissionDecisionReason = 'read-only',
                },
              }
            end
          end,
          Stop = function()
            error('broken callback')
          end,
        },
      })
      cc.start('claude')
      _G.bufnr = cc.open('claude')
      _G.token = require('bodgery.terminal').terminals[bufnr].token
      _G.fired = h.record_events()
      _G.SID = 'session-1'

      --- Posts fixture `name` with the session id `sid` (default SID).
      function _G.send(name, sid, overrides)
        local payload =
          h.fixture(name, vim.tbl_extend('force', { session_id = sid or SID }, overrides or {}))
        return h.post_hook(cc.server.port, token, payload)
      end

      --- Names of fired events, optionally only those matching `pattern`.
      function _G.names(pattern)
        local out = {}
        for _, e in ipairs(fired) do
          if not pattern or e[1]:find(pattern) then
            out[#out + 1] = e[1]
          end
        end
        return out
      end
    end)
  end)

  after_each(function()
    exec_lua(function()
      h.eq({}, h.stop_plugin(before), 'leaked handles')
    end)
  end)

  it('binds the session on SessionStart', function()
    exec_lua(function()
      send('SessionStart-startup')
      h.eq({
        {
          'ClaudeSessionEnter',
          { session_id = SID, bufnr = bufnr, config = 'claude', source = 'startup' },
        },
      }, fired)
      h.eq(SID, require('bodgery.terminal').terminals[bufnr].session_id)
    end)
  end)

  it('binds the session through the SessionStart command hook', function()
    exec_lua(function()
      local path = vim.fs.joinpath(cc.harnesses.claude.state.dir, 'settings.json')
      local settings = vim.json.decode(table.concat(vim.fn.readfile(path), '\n'))
      local done
      -- asynchronous, since this Neovim serves the request
      vim.system({ 'sh', '-c', settings.hooks.SessionStart[1].hooks[1].command }, {
        stdin = vim.json.encode(h.fixture('SessionStart-startup', { session_id = SID })),
        env = { BODGERY_TOKEN = token },
      }, function(res)
        done = res
      end)
      h.wait(function()
        return done
      end, 'curl')
      h.eq({ 0, '{}' }, { done.code, done.stdout })
      h.eq({
        {
          'ClaudeSessionEnter',
          { session_id = SID, bufnr = bufnr, config = 'claude', source = 'startup' },
        },
      }, fired)
    end)
  end)

  it('leaves the old session before entering a new one', function()
    exec_lua(function()
      send('SessionStart-startup')
      send('SessionStart-resume', 'session-2')
      send('SessionStart-clear', 'session-3')
      h.eq({
        {
          'ClaudeSessionEnter',
          { session_id = SID, bufnr = bufnr, config = 'claude', source = 'startup' },
        },
        { 'ClaudeSessionLeave', { session_id = SID, bufnr = bufnr, config = 'claude' } },
        {
          'ClaudeSessionEnter',
          { session_id = 'session-2', bufnr = bufnr, config = 'claude', source = 'resume' },
        },
        { 'ClaudeSessionLeave', { session_id = 'session-2', bufnr = bufnr, config = 'claude' } },
        {
          'ClaudeSessionEnter',
          { session_id = 'session-3', bufnr = bufnr, config = 'claude', source = 'clear' },
        },
      }, fired)
    end)
  end)

  it('tracks tool use and touched files', function()
    exec_lua(function()
      send('SessionStart-startup')
      local steps = { 'Read', 'Edit', 'Write', 'NotebookEdit' }
      for _, tool in ipairs(steps) do
        send('PreToolUse-' .. tool)
        send('PostToolUse-' .. tool)
      end
      h.eq({
        'ClaudeToolUsePre',
        'ClaudeToolUsePost',
        'ClaudeToolUsePre',
        'ClaudeToolUsePost',
        'ClaudeToolUsePre',
        'ClaudeToolUsePost',
        'ClaudeToolUsePre',
        'ClaudeToolUsePost',
      }, names('ToolUse'))

      local touched = cc.touched(SID, 'claude')
      h.eq(3, #touched)
      h.eq('a.txt', vim.fs.basename(touched[1]))
      h.eq('b.txt', vim.fs.basename(touched[2]))
      h.eq('n.ipynb', vim.fs.basename(touched[3]))
      -- Read and Edit of a.txt grow the list once
      h.eq({ 'ClaudeFilesChanged', 'ClaudeFilesChanged', 'ClaudeFilesChanged' }, names('FilesChanged'))
      local last
      for _, e in ipairs(fired) do
        last = e[1] == 'ClaudeFilesChanged' and e or last
      end
      h.eq(touched, last[2].files)
    end)
  end)

  it("sets 'autoread' on an edited buffer until the edit is read back", function()
    exec_lua(function()
      -- the 'autoread' filewatcher arrived in 0.13
      if not pcall(require, 'nvim.autoread') then
        return
      end
      vim.o.autoread = false
      local path = vim.fn.tempname()
      vim.fn.writefile({ 'old' }, path)
      local buf = vim.fn.bufadd(path)
      vim.fn.bufload(buf)

      local input = h.fixture('PreToolUse-Edit').tool_input
      send('SessionStart-startup')
      send('PreToolUse-Edit', nil, { tool_input = vim.tbl_extend('force', input, { file_path = path }) })
      h.eq(true, vim.api.nvim_get_option_value('autoread', { buf = buf }))

      vim.fn.writefile({ 'new' }, path)
      h.wait(function()
        return vim.api.nvim_buf_get_lines(buf, 0, -1, false)[1] == 'new'
      end, 'reload')
      h.eq(vim.NIL, vim.api.nvim_get_option_value('autoread', { buf = buf }) or vim.NIL)
    end)
  end)

  it('opens and closes subtasks', function()
    exec_lua(function()
      send('SessionStart-startup')
      send('PreToolUse-Bash')
      send('PostToolUse-Bash')
      send('PostToolUse-Bash-foreground')
      send('SubagentStart')
      local task_id = h.fixture('PostToolUse-Bash').tool_response.backgroundTaskId
      send('SubagentStop', nil, {
        background_tasks = { { id = task_id, type = 'shell', status = 'running', description = 'sleep' } },
      })
      h.eq({ 'ClaudeSubtaskOpen', 'ClaudeSubtaskOpen', 'ClaudeSubtaskClose' }, names('Subtask'))
      local opened = vim.tbl_filter(function(e)
        return e[1] == 'ClaudeSubtaskOpen'
      end, fired)
      h.eq('bash', opened[1][2].subtask.kind)
      h.eq('agent', opened[2][2].subtask.kind)

      -- the background task is gone from Stop's list
      send('Stop', nil, { background_tasks = {} })
      h.eq('ClaudeSubtaskClose', names('Subtask')[4])
      h.eq(2, #cc.subtasks(SID, 'claude'))
    end)
  end)

  it('reports status changes once each', function()
    exec_lua(function()
      send('SessionStart-startup')
      send('UserPromptSubmit')
      send('UserPromptSubmit')
      send('Notification')
      send('PreToolUse-Read')
      send('Stop')
      local statuses = {}
      for _, e in ipairs(fired) do
        if e[1] == 'ClaudeStatusChanged' then
          statuses[#statuses + 1] = e[2].status
        end
      end
      h.eq({ 'busy', 'waiting', 'busy', 'idle' }, statuses)
    end)
  end)

  it('leaves the session on SessionEnd', function()
    exec_lua(function()
      send('SessionStart-startup')
      send('SessionEnd')
      h.eq({ 'ClaudeSessionEnter', 'ClaudeSessionLeave' }, names())
      h.eq(nil, require('bodgery.terminal').terminals[bufnr].session_id)
    end)
  end)

  it('puts session_id, bufnr, and config in every event', function()
    exec_lua(function()
      local names = vim.fn.readdir(h.root .. '/test/fixtures/hooks')
      table.sort(names)
      send('SessionStart-startup')
      for _, file in ipairs(names) do
        send(file:gsub('%.json$', ''))
      end
      assert(#fired > 10, #fired)
      for _, e in ipairs(fired) do
        assert(e[2].session_id and e[2].bufnr == bufnr and e[2].config == 'claude', vim.inspect(e))
      end
    end)
  end)

  it('returns callback decisions and survives a raising callback', function()
    exec_lua(function()
      send('SessionStart-startup')
      h.eq({
        hookSpecificOutput = {
          hookEventName = 'PreToolUse',
          permissionDecision = 'deny',
          permissionDecisionReason = 'read-only',
        },
      }, send('PreToolUse-Write').json)
      h.eq({}, send('PreToolUse-Read').json)
      h.eq('{}', send('PreToolUse-Read').body)

      local res = send('Stop')
      h.eq({ 200, '{}' }, { res.status, res.body })
      h.eq(1, #notifications)
      assert(notifications[1]:find('broken callback'), notifications[1])
    end)
  end)

  -- Neovim reports autocmd errors itself without raising to the caller
  it('survives a raising User autocmd and still runs the callback', function()
    exec_lua(function()
      send('SessionStart-startup')
      vim.api.nvim_create_autocmd('User', {
        pattern = 'ClaudeToolUsePre',
        callback = function()
          error('broken autocmd')
        end,
      })
      local res = send('PreToolUse-Write')
      h.eq(200, res.status)
      h.eq('deny', res.json.hookSpecificOutput.permissionDecision)
      h.eq({ 'ClaudeToolUsePre', 'ClaudeFilesChanged' }, names('Claude[TF]'))
    end)
  end)
end)
