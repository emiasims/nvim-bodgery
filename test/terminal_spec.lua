local helpers = require('test.helpers')
local exec_lua = require('nvim-test.helpers').exec_lua

describe('terminal', function()
  before_each(function()
    helpers.clear()
    exec_lua(function()
      _G.h = require('test.helpers')
      _G.before = h.handles()
      _G.cc = require('bodgery')
      _G.terminal = require('bodgery.terminal')
      cc.setup({ cmd = h.fake_cmd({ '--model', 'opus', '--verbose' }) })
      cc.start('claude')
      _G.run_dir = vim.fs.joinpath(vim.fn.stdpath('run'), 'bodgery', tostring(cc.server.port))
    end)
  end)

  after_each(function()
    exec_lua(function()
      h.eq({}, h.stop_plugin(before), 'leaked handles')
    end)
  end)

  it('passes the user flags, then --mcp-config and --settings', function()
    exec_lua(function()
      local rec = h.record(cc.open('claude'))
      h.eq({
        '--model',
        'opus',
        '--verbose',
        '--mcp-config',
        run_dir .. '/mcp.json',
        '--settings',
        run_dir .. '/settings.json',
      }, rec.argv)
      local settings = vim.json.decode(table.concat(vim.fn.readfile(run_dir .. '/settings.json')))
      h.eq('Read|Edit|Write|NotebookEdit|Bash', settings.hooks.PreToolUse[1].matcher)
      h.eq('command', settings.hooks.SessionStart[1].hooks[1].type)
      h.eq({ 'BODGERY_TOKEN' }, settings.hooks.Stop[1].hooks[1].allowedEnvVars)
    end)
  end)

  it('launches each config with its own flags', function()
    exec_lua(function()
      cc.setup({ name = 'plain', cmd = h.fake_cmd() })
      local a, b = cc.open('claude'), cc.open('plain')
      h.eq('--model', h.record(a).argv[1])
      h.eq('--mcp-config', h.record(b).argv[1])
      h.eq('claude', terminal.terminals[a].config.name)
      h.eq('plain', terminal.terminals[b].config.name)
    end)
  end)

  it('sets the environment Claude reads', function()
    exec_lua(function()
      local bufnr = cc.open('claude')
      local env = h.record(bufnr).env
      h.eq(tostring(cc.server.port), env.CLAUDE_CODE_SSE_PORT)
      h.eq(terminal.terminals[bufnr].token, env.BODGERY_TOKEN)
      h.eq(h.root .. '/bin/bodgery-editor', env.EDITOR)
      h.eq('true', env.FORCE_CODE_TERMINAL)
    end)
  end)

  it('adds the loopback hosts to no_proxy once each', function()
    exec_lua(function()
      vim.env.no_proxy = 'example.com,localhost'
      vim.env.NO_PROXY = nil
      local env = h.record(cc.open('claude')).env
      h.eq('example.com,localhost,127.0.0.1', env.no_proxy)
      h.eq('127.0.0.1,localhost', env.NO_PROXY)
    end)
  end)

  it('keeps the token out of the buffer name, argv, and launch files', function()
    exec_lua(function()
      local bufnr = cc.open('claude')
      local token = terminal.terminals[bufnr].token
      local rec = h.record(bufnr)
      local texts = {
        vim.api.nvim_buf_get_name(bufnr),
        table.concat(rec.argv, ' '),
        table.concat(vim.fn.readfile(run_dir .. '/settings.json')),
        table.concat(vim.fn.readfile(run_dir .. '/mcp.json')),
      }
      for _, text in ipairs(texts) do
        assert(not text:find(token, 1, true), text)
      end

      local mcp = vim.json.decode(texts[4])
      h.eq('Bearer ${BODGERY_TOKEN}', mcp.mcpServers.nvim.headers.Authorization)
      local settings = vim.json.decode(texts[3])
      h.eq('Bearer $BODGERY_TOKEN', settings.hooks.Stop[1].hooks[1].headers.Authorization)
    end)
  end)

  it('replaces only the current window buffer without mods', function()
    exec_lua(function()
      vim.cmd('split | tabnew | vsplit')
      local before = h.layout()
      local bufnr = cc.open('claude')
      local win = vim.api.nvim_get_current_win()
      local function patch(node)
        if node[1] == 'leaf' then
          return node[2] == win and { 'leaf', win, bufnr } or node
        end
        return { node[1], vim.tbl_map(patch, node[2]) }
      end
      h.eq(vim.tbl_map(patch, before), h.layout())
      h.eq('terminal', vim.bo[bufnr].buftype)
    end)
  end)

  it('opens splits like :split with the same modifiers', function()
    exec_lua(function()
      local function reset()
        vim.cmd('silent! tabonly! | silent! only! | enew | split | tabnew | vsplit')
      end
      for _, opt in ipairs({ true, false }) do
        vim.o.splitright, vim.o.splitbelow = opt, opt
        for _, mods in ipairs({ '', 'vertical', 'tab', 'botright', 'vertical topleft' }) do
          local label = ('%s (split options %s)'):format(mods, opt)
          reset()
          vim.cmd(mods .. ' split')
          local expected = h.shape()

          reset()
          local other = h.layout()[1]
          vim.cmd(mods .. ' Claude')
          h.eq(expected, h.shape(), ':' .. label)
          h.eq('terminal', vim.bo.buftype, label)
          h.eq(other, h.layout()[1], 'other tab after :' .. label)

          reset()
          cc.open('claude', { mods = vim.api.nvim_parse_cmd(mods .. ' split', {}).mods })
          h.eq(expected, h.shape(), 'open() ' .. label)
        end
      end
    end)
  end)

  it('gives each terminal its own token', function()
    exec_lua(function()
      cc.server:route({
        method = 'GET',
        path = '/whoami',
        handler = function(req)
          return 200, { bufnr = req.ctx.bufnr }
        end,
      })
      local a = cc.open('claude')
      local b = cc.open('claude', { mods = {} })
      local ta, tb = terminal.terminals[a].token, terminal.terminals[b].token
      assert(ta ~= tb)
      h.eq(a, h.request(cc.server.port, 'GET', '/whoami', { token = ta }).json.bufnr)
      h.eq(b, h.request(cc.server.port, 'GET', '/whoami', { token = tb }).json.bufnr)

      vim.cmd.bwipeout({ a, bang = true })
      h.eq(nil, terminal.terminals[a])
      h.eq(401, h.request(cc.server.port, 'GET', '/whoami', { token = ta }).status)
      h.eq(200, h.request(cc.server.port, 'GET', '/whoami', { token = tb }).status)
    end)
  end)

  it('writes the lockfile with mode 0600 and removes it on stop()', function()
    exec_lua(function()
      local path = ('%s/ide/%d.lock'):format(vim.env.CLAUDE_CONFIG_DIR, cc.server.port)
      local lock = vim.json.decode(table.concat(vim.fn.readfile(path)))
      local keys = vim.tbl_keys(lock)
      table.sort(keys)
      h.eq({ 'authToken', 'ideName', 'pid', 'transport', 'workspaceFolders' }, keys)
      h.eq(vim.fn.getpid(), lock.pid)
      h.eq({ vim.fn.getcwd() }, lock.workspaceFolders)
      h.eq({ 'Neovim', 'ws' }, { lock.ideName, lock.transport })
      h.eq(32, #lock.authToken)
      h.eq(tonumber('600', 8), vim.uv.fs_stat(path).mode % 512)

      local c, res = h.ws_connect(cc.server.port, lock.authToken)
      h.eq(101, res.status)
      c:close()

      cc.stop()
      h.eq(nil, vim.uv.fs_stat(path))
      h.eq(nil, vim.uv.fs_stat(run_dir))
    end)
  end)

  it('removes the lockfile on VimLeavePre', function()
    exec_lua(function()
      local path = ('%s/ide/%d.lock'):format(vim.env.CLAUDE_CONFIG_DIR, cc.server.port)
      assert(vim.uv.fs_stat(path), 'lockfile missing')
      vim.api.nvim_exec_autocmds('VimLeavePre', {})
      h.eq(nil, vim.uv.fs_stat(path))
      h.eq(nil, vim.uv.fs_stat(run_dir))
    end)
  end)

  it('sets the harness name as the filetype', function()
    exec_lua(function()
      h.eq('claude', vim.bo[cc.open('claude')].filetype)
    end)
  end)

  it('puts :Claude arguments after --settings', function()
    exec_lua(function()
      vim.cmd('Claude --resume x')
      local argv = h.record(vim.api.nvim_get_current_buf()).argv
      h.eq({ '--settings', run_dir .. '/settings.json', '--resume', 'x' }, vim.list_slice(argv, #argv - 3))
    end)
  end)

  it('picks a config by name when several share a command', function()
    exec_lua(function()
      cc.setup({ name = 'work', cmd = h.fake_cmd({ '--model', 'sonnet' }) })
      vim.cmd('Claude work --resume x')
      local work = vim.api.nvim_get_current_buf()
      vim.cmd('Claude --resume y')
      local default = vim.api.nvim_get_current_buf()
      h.eq('work', terminal.terminals[work].config.name)
      h.eq('claude', terminal.terminals[default].config.name)
      local argv = h.record(work).argv
      h.eq({ '--model', 'sonnet' }, vim.list_slice(argv, 1, 2))
      h.eq({ '--resume', 'x' }, vim.list_slice(argv, #argv - 1))
      h.eq({ 'claude', 'work' }, vim.fn.getcompletion('Claude ', 'cmdline'))
    end)
  end)

  it('defines the command named by opts.command, and removes one no config uses', function()
    exec_lua(function()
      cc.setup({ name = 'other', command = 'Agent', cmd = h.fake_cmd() })
      vim.cmd('Agent')
      h.eq('other', terminal.terminals[vim.api.nvim_get_current_buf()].config.name)
      cc.setup({ name = 'other', command = 'Helper', cmd = h.fake_cmd() })
      h.eq({ 0, 2 }, { vim.fn.exists(':Agent'), vim.fn.exists(':Helper') })
    end)
  end)
end)
