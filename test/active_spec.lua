local helpers = require('test.helpers')
local exec_lua = require('nvim-test.helpers').exec_lua

describe('active terminal', function()
  before_each(function()
    helpers.clear()
    exec_lua(function()
      _G.h = require('test.helpers')
      _G.before = h.handles()
      _G.cc = require('bodgery')
      cc.setup({ cmd = h.fake_cmd() })
      cc.start('claude')
      _G.terminal = require('bodgery.terminal')

      --- Waits until fake-claude in `bufnr` has read `lines` from its terminal.
      function _G.stdin(bufnr, lines)
        return h.record(bufnr, function(rec)
          return #rec.stdin >= #lines
        end).stdin
      end

      --- Sets a terminal's status the way hooks do.
      function _G.status(bufnr, s)
        local term = terminal.terminals[bufnr]
        term.session_id = term.session_id or 'sid'
        local event = ({ busy = 'UserPromptSubmit', idle = 'Stop' })[s]
        h.post_hook(cc.server.port, term.token, h.fixture(event, { session_id = term.session_id }))
        h.eq(s, term.status)
      end

      --- Replaces vim.ui.select, recording each call and answering with `pick(items)`.
      function _G.stub_select(pick)
        local calls = {}
        vim.ui.select = function(items, opts, on_choice)
          calls[#calls + 1] = { items = items, opts = opts }
          on_choice(pick(items))
        end
        return calls
      end

      function _G.err(fn, ...)
        local ok, e = pcall(fn, ...)
        h.eq(false, ok)
        return e
      end
    end)
  end)

  after_each(function()
    exec_lua(function()
      h.eq({}, h.stop_plugin(before), 'leaked handles')
    end)
  end)

  describe('resume', function()
    it('targets the current terminal, then the tab record, then the global one', function()
      exec_lua(function()
        h.eq('bodgery: pass a config to resume in a new terminal', err(cc.resume, 'x'))

        local a = cc.open('claude')
        h.eq({ a, a }, { vim.g.bodgery_term, vim.t.bodgery_term })
        cc.resume('one')
        h.eq({ '/resume one' }, stdin(a, { 1 }))

        vim.cmd.vsplit()
        vim.cmd.enew()
        local win = vim.api.nvim_get_current_win()
        cc.resume('two')
        h.eq({ '/resume one', '/resume two' }, stdin(a, { 1, 2 }))
        h.eq({ nil, a }, { vim.w.bodgery_term, vim.t.bodgery_term })

        local b = cc.open('claude', { mods = { split = 'belowright' } })
        h.eq({ b, b }, { vim.g.bodgery_term, vim.t.bodgery_term })
        vim.api.nvim_set_current_win(win)
        cc.resume('three')
        h.eq({ '/resume three' }, stdin(b, { 1 }))

        vim.cmd.tabnew()
        cc.resume('four')
        h.eq({ '/resume three', '/resume four' }, stdin(b, { 1, 2 }))
        h.eq(b, vim.t.bodgery_term)

        cc.resume('five', a)
        h.eq({ '/resume one', '/resume two', '/resume five' }, stdin(a, { 1, 2, 3 }))
      end)
    end)

    it('ignores moving between windows', function()
      exec_lua(function()
        local a = cc.open('claude')
        vim.cmd.vsplit()
        vim.cmd.enew()
        local file = vim.api.nvim_get_current_win()
        local b = cc.open('claude', { mods = {} })
        vim.api.nvim_set_current_win(file)
        vim.api.nvim_set_current_win(vim.fn.win_findbuf(a)[1])
        vim.api.nvim_set_current_win(file)
        h.eq({ b, b }, { vim.g.bodgery_term, vim.t.bodgery_term })
        cc.resume('x')
        h.eq({ '/resume x' }, stdin(b, { 1 }))
        h.eq({}, h.record(a).stdin)
      end)
    end)

    it('moves the records of a terminal another replaces in its window', function()
      exec_lua(function()
        local a = cc.open('claude')
        vim.cmd.tabnew()
        local b = cc.open('claude')
        h.eq(b, vim.t.bodgery_term)

        vim.cmd.tabnew()
        cc.toggle()
        h.eq({ b, b }, { vim.api.nvim_get_current_buf(), vim.t.bodgery_term })
        vim.cmd.buffer(a)
        h.eq({ a, a }, { vim.t.bodgery_term, vim.g.bodgery_term })
        vim.cmd.buffer(b)
        h.eq(b, vim.t.bodgery_term)

        vim.cmd.vsplit()
        vim.cmd.enew()
        local file = vim.api.nvim_get_current_win()
        vim.w[file].bodgery_term = a
        vim.cmd.wincmd('p')
        vim.cmd.buffer(a)
        h.eq({ a, a }, { vim.t.bodgery_term, vim.w[file].bodgery_term })
        vim.cmd.buffer(b)
        h.eq({ b, b }, { vim.t.bodgery_term, vim.w[file].bodgery_term })
        h.eq(b, vim.t[2].bodgery_term)
      end)
    end)

    it('finds the terminal of the current project', function()
      exec_lua(function()
        local root = vim.fn.tempname()
        for _, p in ipairs({ 'p1', 'p2' }) do
          vim.fn.mkdir(('%s/%s/.git'):format(root, p), 'p')
        end
        local p1 = cc.open('claude', { cwd = root .. '/p1' })
        cc.open('claude', { cwd = root .. '/p2' })
        vim.cmd.tabnew(root .. '/p1/x.txt')
        cc.resume('x', nil, { name = 'claude', active = { 'project', 'error' } })
        h.eq({ '/resume x' }, stdin(p1, { 1 }))

        vim.cmd.tabnew(root .. '/elsewhere.txt')
        h.eq(
          'bodgery: no agent terminal found, pass a bufnr',
          err(cc.resume, 'y', nil, { name = 'claude', active = { 'project', 'error' } })
        )
      end)
    end)

    it('asks which terminal with pick', function()
      exec_lua(function()
        local a = cc.open('claude')
        local b = cc.open('claude')
        vim.cmd.tabnew()
        local calls = stub_select(function(items)
          return items[1]
        end)
        cc.resume('x', nil, { name = 'claude', active = { 'pick' } })
        h.eq({ a, b }, { calls[1].items[1].bufnr, calls[1].items[2].bufnr })
        h.eq({ '/resume x' }, stdin(a, { 1 }))
      end)
    end)

    it('raises, interrupts, or queues when Claude is busy', function()
      exec_lua(function()
        local bufnr = cc.open('claude')
        status(bufnr, 'busy')
        h.eq('bodgery: claude is busy in buffer ' .. bufnr, err(cc.resume, 'x'))

        cc.configs.claude.on_busy = 'interrupt'
        cc.resume('now')
        h.eq({ '\27/resume now' }, stdin(bufnr, { 1 }))

        cc.configs.claude.on_busy = 'queue'
        cc.resume('later')
        vim.wait(3 * terminal.submit_delay)
        h.eq(1, #h.record(bufnr).stdin)
        status(bufnr, 'idle')
        h.eq({ '\27/resume now', '/resume later' }, stdin(bufnr, { 1, 2 }))
      end)
    end)

    it('asks what to do when on_busy is prompt', function()
      exec_lua(function()
        cc.configs.claude.on_busy = 'prompt'
        local bufnr = cc.open('claude')
        status(bufnr, 'busy')
        local calls = stub_select(function(items)
          return items[2]
        end)
        cc.resume('x')
        h.eq({ 'interrupt', 'queue' }, calls[1].items)
        h.eq('Send when idle', calls[1].opts.format_item('queue'))
        status(bufnr, 'idle')
        h.eq({ '/resume x' }, stdin(bufnr, { 1 }))
      end)
    end)

    it('clears the records of an exited terminal and falls back past them', function()
      exec_lua(function()
        local a = cc.open('claude')
        vim.cmd.tabnew()
        local b = cc.open('claude')
        vim.cmd.vsplit()
        vim.cmd.enew()
        vim.w.bodgery_term, vim.b.bodgery_term = b, b
        h.eq({ b, b }, { vim.g.bodgery_term, vim.t.bodgery_term })

        vim.fn.jobstop(terminal.terminals[b].job)
        vim.wait(1000, function()
          return not terminal.terminals[b]
        end)
        h.eq({ a }, { vim.g.bodgery_term, vim.t.bodgery_term, vim.w.bodgery_term, vim.b.bodgery_term })
        cc.resume('x')
        h.eq({ '/resume x' }, stdin(a, { 1 }))

        vim.fn.jobstop(terminal.terminals[a].job)
        vim.wait(1000, function()
          return not terminal.terminals[a]
        end)
        h.eq({}, { vim.g.bodgery_term, vim.t.bodgery_term })
      end)
    end)

    it('opens a new terminal in the current window when the chain reaches new', function()
      exec_lua(function()
        local old = cc.open('claude')
        vim.cmd.tabnew()
        vim.cmd.split()
        local layout = h.layout()
        cc.resume('abc', nil, { name = 'claude', active = { 'new' } })

        local new = vim.api.nvim_get_current_buf()
        assert(new ~= old and terminal.terminals[new], 'expected a new Claude terminal')
        local argv = h.record(new).argv
        h.eq({ '--resume', 'abc' }, vim.list_slice(argv, #argv - 1))
        layout[2][2][1][3] = new
        h.eq(layout, h.layout())
        h.eq({ -1 }, vim.fn.jobwait({ terminal.terminals[old].job }, 0))
      end)
    end)
  end)

  describe('toggle', function()
    it('opens, hides, and shows again from the window it was opened from', function()
      exec_lua(function()
        h.eq('bodgery: pass a config to start a new terminal', err(cc.toggle))
        local file = vim.api.nvim_get_current_win()

        cc.toggle(nil, 'claude')
        local bufnr = vim.api.nvim_get_current_buf()
        assert(terminal.terminals[bufnr], 'expected to enter the new terminal')
        h.eq(2, #vim.api.nvim_tabpage_list_wins(0))

        cc.toggle()
        h.eq({ file }, vim.api.nvim_tabpage_list_wins(0))
        assert(vim.api.nvim_buf_is_valid(bufnr), 'hiding kept the terminal')

        cc.toggle()
        h.eq(bufnr, vim.api.nvim_get_current_buf())

        vim.api.nvim_set_current_win(file)
        cc.toggle()
        h.eq({ file }, vim.api.nvim_tabpage_list_wins(0))
      end)
    end)

    it('shows the alternate buffer when the terminal is alone in its tab', function()
      exec_lua(function()
        vim.cmd.edit(vim.fn.tempname())
        local file = vim.api.nvim_get_current_buf()
        local bufnr = cc.open('claude')
        cc.toggle()
        h.eq(file, vim.api.nvim_get_current_buf())
        cc.toggle()
        h.eq(bufnr, vim.api.nvim_get_current_buf())
      end)
    end)

    it('makes a terminal given by bufnr or picked the target of the tab', function()
      exec_lua(function()
        local a = cc.open('claude')
        local b = cc.open('claude')
        vim.cmd.tabnew()
        cc.toggle()
        h.eq(b, vim.api.nvim_get_current_buf())
        cc.toggle()

        cc.toggle(a)
        h.eq({ a, a }, { vim.api.nvim_get_current_buf(), vim.t.bodgery_term })
        cc.hide()
        cc.hide()
        h.eq(nil, terminal.terminals[vim.api.nvim_get_current_buf()])
        cc.show()
        h.eq(a, vim.api.nvim_get_current_buf())
        cc.show()
        h.eq(a, vim.api.nvim_get_current_buf())

        stub_select(function(items)
          return items[2]
        end)
        require('bodgery.select').terminals()
        h.eq({ b, b }, { vim.api.nvim_get_current_buf(), vim.t.bodgery_term })
      end)
    end)

    it('follows the chain in a tab the terminal was never used from', function()
      exec_lua(function()
        local a = cc.open('claude')
        vim.cmd.tabnew()
        cc.toggle()
        h.eq(a, vim.api.nvim_get_current_buf())

        vim.cmd.tabnew()
        cc.toggle(nil, { name = 'claude', active = { 'window', 'tab', 'new' } })
        local b = vim.api.nvim_get_current_buf()
        assert(b ~= a and terminal.terminals[b], 'expected a new terminal')
      end)
    end)
  end)

  it('picks sessions, subtasks, and touched files through vim.ui.select', function()
    exec_lua(function()
      local pick = require('bodgery.select')
      local cwd = vim.fn.getcwd()
      local dir = vim.env.CLAUDE_CONFIG_DIR .. '/projects/' .. cwd:gsub('[^%w]', '-')
      vim.fn.mkdir(dir, 'p')
      local line = { type = 'user', message = { role = 'user', content = 'hello there' }, cwd = cwd }
      vim.fn.writefile({ vim.json.encode(line) }, dir .. '/s1.jsonl')

      local calls = stub_select(function(items)
        return items[1]
      end)
      pick.sessions('claude')
      h.eq('s1', calls[1].items[1].id)
      assert(calls[1].opts.format_item(calls[1].items[1]):find('hello there', 1, true))
      local bufnr = vim.api.nvim_get_current_buf()
      local argv = h.record(bufnr).argv
      h.eq({ '--resume', 's1' }, vim.list_slice(argv, #argv - 1))

      local file = vim.fn.tempname()
      vim.fn.writefile({ 'x' }, file)
      require('bodgery.harness.claude.hooks').sessions.sid = {
        touched = { file },
        subtasks = { t1 = { id = 't1', kind = 'bash', description = 'sleep', open = true, path = file } },
      }
      terminal.terminals[bufnr].session_id = 'sid'

      pick.touched()
      h.eq({ file }, calls[2].items)
      h.eq(vim.uv.fs_realpath(file), vim.uv.fs_realpath(vim.api.nvim_buf_get_name(0)))

      vim.api.nvim_win_set_buf(0, bufnr)
      local chosen
      pick.subtasks({
        on_choice = function(t)
          chosen = t
        end,
      })
      h.eq('t1', chosen.id)
      h.eq('* bash  sleep', calls[3].opts.format_item(chosen))
    end)
  end)
end)
