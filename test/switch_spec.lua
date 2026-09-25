local helpers = require('test.helpers')
local exec_lua = require('nvim-test.helpers').exec_lua

describe('switch', function()
  before_each(function()
    helpers.clear()
    exec_lua(function()
      _G.h = require('test.helpers')
      _G.before = h.handles()
      _G.cc = require('bodging')
      cc.setup({ cmd = h.fake_cmd() })
      cc.start('claude')
      _G.terminal = require('bodging.terminal')

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
    end)
  end)

  after_each(function()
    exec_lua(function()
      h.eq({}, h.stop_plugin(before), 'leaked handles')
    end)
  end)

  it('targets the one Claude terminal shown, and raises for none or two', function()
    exec_lua(function()
      local function err(...)
        local ok, e = pcall(cc.switch, ...)
        h.eq(false, ok)
        return e
      end
      h.eq('bodging: no Claude terminals shown, pass a bufnr or set opts.resolve', err('x'))

      local a = cc.open()
      cc.switch('one')
      h.eq({ '/resume one' }, stdin(a, { 1 }))

      local b = cc.open({ mods = { split = 'belowright' } })
      h.eq('bodging: 2 Claude terminals shown, pass a bufnr or set opts.resolve', err('x'))
      cc.switch(b, 'two')
      h.eq({ '/resume two' }, stdin(b, { 1 }))

      cc.configs.claude.resolve = function()
        return a
      end
      cc.switch('three')
      h.eq({ '/resume one', '/resume three' }, stdin(a, { 1, 2 }))
    end)
  end)

  it('raises, interrupts, or queues when Claude is busy', function()
    exec_lua(function()
      local bufnr = cc.open()
      status(bufnr, 'busy')
      local ok, e = pcall(cc.switch, 'x')
      h.eq({ false, 'bodging: Claude is busy in buffer ' .. bufnr }, { ok, e })

      cc.configs.claude.on_busy = 'interrupt'
      cc.switch('now')
      h.eq({ '\27/resume now' }, stdin(bufnr, { 1 }))

      cc.configs.claude.on_busy = 'queue'
      cc.switch('later')
      vim.wait(3 * terminal.submit_delay)
      h.eq(1, #h.record(bufnr).stdin)
      status(bufnr, 'idle')
      h.eq({ '\27/resume now', '/resume later' }, stdin(bufnr, { 1, 2 }))
    end)
  end)

  it('asks what to do when on_busy is prompt', function()
    exec_lua(function()
      cc.configs.claude.on_busy = 'prompt'
      local bufnr = cc.open()
      status(bufnr, 'busy')
      local calls = stub_select(function(items)
        return items[2]
      end)
      cc.switch('x')
      h.eq({ 'interrupt', 'queue' }, calls[1].items)
      h.eq('Resume when idle', calls[1].opts.format_item('queue'))
      status(bufnr, 'idle')
      h.eq({ '/resume x' }, stdin(bufnr, { 1 }))
    end)
  end)

  it('opens a new terminal in the current window with new = true', function()
    exec_lua(function()
      local old = cc.open()
      vim.cmd.tabnew()
      vim.cmd.split()
      local layout = h.layout()
      cc.switch('abc', { new = true })

      local new = vim.api.nvim_get_current_buf()
      assert(new ~= old and terminal.terminals[new], 'expected a new Claude terminal')
      local argv = h.record(new).argv
      h.eq({ '--resume', 'abc' }, vim.list_slice(argv, #argv - 1))
      layout[2][2][1][3] = new
      h.eq(layout, h.layout())
      h.eq({ -1 }, vim.fn.jobwait({ terminal.terminals[old].job }, 0))
    end)
  end)

  it('picks sessions, subtasks, and touched files through vim.ui.select', function()
    exec_lua(function()
      local pick = require('bodging.select')
      local cwd = vim.fn.getcwd()
      local dir = vim.env.CLAUDE_CONFIG_DIR .. '/projects/' .. cwd:gsub('[^%w]', '-')
      vim.fn.mkdir(dir, 'p')
      local line = { type = 'user', message = { role = 'user', content = 'hello there' }, cwd = cwd }
      vim.fn.writefile({ vim.json.encode(line) }, dir .. '/s1.jsonl')

      local calls = stub_select(function(items)
        return items[1]
      end)
      pick.sessions()
      h.eq('s1', calls[1].items[1].id)
      assert(calls[1].opts.format_item(calls[1].items[1]):find('hello there', 1, true))
      local bufnr = vim.api.nvim_get_current_buf()
      local argv = h.record(bufnr).argv
      h.eq({ '--resume', 's1' }, vim.list_slice(argv, #argv - 1))

      local file = vim.fn.tempname()
      vim.fn.writefile({ 'x' }, file)
      require('bodging.harness.claude.hooks').sessions.sid = {
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
