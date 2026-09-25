local helpers = require('test.helpers')
local exec_lua = require('nvim-test.helpers').exec_lua

describe('hooks', function()
  before_each(function()
    helpers.clear()
    exec_lua(function()
      _G.h = require('test.helpers')
      _G.cc = require('claude-code')
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
      _G.bufnr = cc.open()
      _G.token = require('claude-code.terminal').terminals[bufnr].token
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

  it('binds the session on SessionStart', function()
    exec_lua(function()
      send('SessionStart-startup')
      h.eq({ { 'ClaudeSessionEnter', { session_id = SID, bufnr = bufnr, source = 'startup' } } }, fired)
      h.eq(SID, require('claude-code.terminal').terminals[bufnr].session_id)
    end)
  end)

  it('leaves the old session before entering a new one', function()
    exec_lua(function()
      send('SessionStart-startup')
      send('SessionStart-resume', 'session-2')
      send('SessionStart-clear', 'session-3')
      h.eq({
        { 'ClaudeSessionEnter', { session_id = SID, bufnr = bufnr, source = 'startup' } },
        { 'ClaudeSessionLeave', { session_id = SID, bufnr = bufnr } },
        { 'ClaudeSessionEnter', { session_id = 'session-2', bufnr = bufnr, source = 'resume' } },
        { 'ClaudeSessionLeave', { session_id = 'session-2', bufnr = bufnr } },
        { 'ClaudeSessionEnter', { session_id = 'session-3', bufnr = bufnr, source = 'clear' } },
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

      local touched = cc.touched(SID)
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
      h.eq(2, #cc.subtasks(SID))
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
      h.eq(nil, require('claude-code.terminal').terminals[bufnr].session_id)
    end)
  end)

  it('puts session_id and bufnr in every event', function()
    exec_lua(function()
      local names = vim.fn.readdir(h.root .. '/test/fixtures/hooks')
      table.sort(names)
      send('SessionStart-startup')
      for _, file in ipairs(names) do
        send(file:gsub('%.json$', ''))
      end
      assert(#fired > 10, #fired)
      for _, e in ipairs(fired) do
        assert(e[2].session_id and e[2].bufnr == bufnr, vim.inspect(e))
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
end)
