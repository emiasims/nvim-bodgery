local helpers = require('test.helpers')
local exec_lua = require('nvim-test.helpers').exec_lua

describe('sessions', function()
  before_each(function()
    helpers.clear()
    exec_lua(function()
      _G.h = require('test.helpers')
      _G.before = h.handles()
      _G.cc = require('bodging')
      cc.setup({ cmd = h.fake_cmd(), ccd_dir = h.root .. '/test/fixtures/ccd' })
      _G.data = require('bodging.harness.claude.sessions')

      local config = vim.env.CLAUDE_CONFIG_DIR
      vim.system({ 'cp', '-R', h.root .. '/test/fixtures/claude/projects', config }):wait()
      vim.fn.mkdir(config .. '/sessions', 'p')
      _G.proj = config .. '/projects/-home-test-proj'

      -- oldest first, one second apart
      _G.order = {
        's-work',
        's-malformed',
        's-dead',
        's-live',
        's-archived',
        's-prompt',
        's-ai',
        's-agent',
        's-custom',
        's-ccd',
        's-collide',
      }
      for i, id in ipairs(order) do
        vim.uv.fs_utime(('%s/%s.jsonl'):format(proj, id), 1e9 + i, 1e9 + i)
      end

      --- Writes Claude's live session file for `id`.
      function _G.live(id, pid, name)
        local rec = { pid = pid, sessionId = id, status = 'idle', name = name }
        vim.fn.writefile({ vim.json.encode(rec) }, ('%s/sessions/%d.json'):format(config, pid))
      end

      --- The pid of a process that has exited.
      function _G.dead_pid()
        local p = vim.system({ 'true' })
        local pid = p.pid
        p:wait()
        return pid
      end

      function _G.collect(filter)
        local out = {}
        for s in cc.sessions('claude', filter) do
          out[#out + 1] = s
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

  it('titles sessions from ccd, title records, the live name, and the first prompt', function()
    exec_lua(function()
      live('s-live', vim.fn.getpid(), 'Live name')
      live('s-dead', dead_pid(), 'Dead name')
      local got = collect({ cwd = '/home/test/proj' })

      local ids = vim.tbl_map(function(s)
        return s.id
      end, got)
      h.eq(vim.fn.reverse(vim.list_slice(order, 1, #order - 1)), ids)

      local by_id = {}
      for _, s in ipairs(got) do
        by_id[s.id] = s
        h.eq('/home/test/proj', s.cwd, s.id)
      end
      local titles = vim.tbl_map(function(s)
        return s.title
      end, by_id)
      h.eq({
        ['s-ccd'] = 'From ccd',
        ['s-custom'] = 'Custom name',
        ['s-agent'] = 'Agent name',
        ['s-ai'] = 'AI title',
        ['s-prompt'] = 'fix the parser',
        ['s-archived'] = 'Old work',
        ['s-live'] = 'Live name',
        ['s-dead'] = 'dead prompt',
        ['s-malformed'] = 'after garbage',
        ['s-work'] = 'do the work',
      }, titles)
      h.eq({ pid = vim.fn.getpid(), status = 'idle', name = 'Live name' }, by_id['s-live'].live)
      h.eq(nil, by_id['s-dead'].live)
      h.eq({ true, false }, { by_id['s-archived'].archived, by_id['s-ccd'].archived })
      h.eq(1e9 + 10, by_id['s-ccd'].last_activity)
    end)
  end)

  it('filters on archived and reports the terminal holding a session', function()
    exec_lua(function()
      local function ids(filter)
        return vim.tbl_map(function(s)
          return s.id
        end, collect(filter))
      end
      h.eq({ 's-archived' }, ids({ archived = true, cwd = '/home/test/proj' }))
      assert(not vim.list_contains(ids({ archived = false }), 's-archived'))
      assert(vim.list_contains(ids({ archived = false }), 's-other'))

      local bufnr = cc.open('claude')
      require('bodging.terminal').terminals[bufnr].session_id = 's-ccd'
      for s in cc.sessions('claude', { cwd = '/home/test/proj' }) do
        h.eq(s.id == 's-ccd' and bufnr or nil, s.bufnr, s.id)
      end
    end)
  end)

  it('opens no transcript outside the filtered project', function()
    exec_lua(function()
      local opened = {}
      local open = io.open
      io.open = function(path, ...)
        opened[#opened + 1] = path
        return open(path, ...)
      end
      collect({ cwd = '/home/test/proj' })
      local outside = vim.tbl_filter(function(p)
        return p:find('/projects/', 1, true) and not vim.startswith(p, proj .. '/')
      end, opened)
      opened = {}
      collect()
      io.open = open

      h.eq({}, outside)
      assert(
        vim.list_contains(opened, vim.env.CLAUDE_CONFIG_DIR .. '/projects/-home-test-other/s-other.jsonl')
      )
    end)
  end)

  it('stops reading a large transcript at the byte cap', function()
    exec_lua(function()
      local path = proj .. '/s-big.jsonl'
      local f = assert(io.open(path, 'w'))
      local line = vim.json.encode({ type = 'progress', data = ('x'):rep(1000) }) .. '\n'
      local block = line:rep(1000)
      for _ = 1, 50 do
        f:write(block)
      end
      f:close()
      h.eq(true, vim.uv.fs_stat(path).size > 50e6)

      local read = 0
      local open = io.open
      io.open = function(p, mode)
        local file = open(p, mode)
        if p ~= path or not file then
          return file
        end
        return {
          read = function(_, n)
            local chunk = file:read(n)
            read = read + (chunk and #chunk or 0)
            return chunk
          end,
          seek = function(_, ...)
            return file:seek(...)
          end,
          close = function()
            return file:close()
          end,
        }
      end
      for s in cc.sessions('claude', { cwd = '/home/test/proj', fields = { 'cwd', 'title' } }) do
        if s.id == 's-big' then
          h.eq({ nil, nil }, { s.cwd, s.title })
        end
      end
      io.open = open
      h.eq(true, read <= data.head_cap + data.tail_bytes, 'read ' .. read)
    end)
  end)

  it('lists touched files from tool calls, subagents, file history, and hooks', function()
    exec_lua(function()
      local expected = {
        '/home/test/proj/a.txt',
        '/home/test/proj/b.txt',
        '/abs/c.txt',
        '/home/test/proj/d.txt',
        '/home/test/proj/n.ipynb',
        '/home/test/proj/e.txt',
      }
      h.eq(expected, cc.touched('s-work', 'claude'))

      require('bodging.harness.claude.hooks').sessions['s-work'] =
        { touched = { '/home/test/proj/b.txt', '/x/new.txt' }, subtasks = {} }
      h.eq(vim.list_extend(vim.list_slice(expected), { '/x/new.txt' }), cc.touched('s-work', 'claude'))
      h.eq({}, cc.touched('no-such-session', 'claude'))
    end)
  end)

  it('opens subtasks only while the session is live and unfinished', function()
    exec_lua(function()
      local function agent(id)
        return ('%s/s-work/subagents/agent-%s.jsonl'):format(proj, id)
      end
      local function open_ids()
        local out = {}
        for _, s in ipairs(cc.subtasks('s-work', 'claude')) do
          if s.open then
            out[#out + 1] = s.id
          end
        end
        return out
      end
      h.eq({
        { id = 'bash1', kind = 'bash', description = 'Sleep', open = false, path = '/tmp/bash1.output' },
        { id = 'bash2', kind = 'bash', description = 'tail -f log', open = false },
        { id = 'agent1', kind = 'agent', description = 'Review', open = false, path = agent('agent1') },
        { id = 'agent2', kind = 'agent', description = 'Search', open = false, path = agent('agent2') },
        { id = 'agent3', kind = 'agent', description = 'Plan', open = false, path = agent('agent3') },
      }, cc.subtasks('s-work', 'claude'))

      live('s-work', vim.fn.getpid())
      h.eq({ 'bash2', 'agent3' }, open_ids())

      require('bodging.harness.claude.hooks').sessions['s-work'] = {
        touched = {},
        subtasks = {
          bash2 = { id = 'bash2', kind = 'bash', open = false },
          bash9 = { id = 'bash9', kind = 'bash', description = 'new', open = true },
        },
      }
      h.eq({ 'agent3', 'bash9' }, open_ids())
    end)
  end)
end)
