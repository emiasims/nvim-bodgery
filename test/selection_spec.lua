local helpers = require('test.helpers')
local exec_lua = require('nvim-test.helpers').exec_lua

describe('selection', function()
  before_each(function()
    helpers.clear()
    exec_lua(function()
      _G.h = require('test.helpers')
      _G.before = h.handles()
      _G.cc = require('claude-code')
      cc.setup({ cmd = h.fake_cmd() })

      _G.path = vim.fn.tempname() .. '.txt'
      vim.fn.writefile({ 'hello world', 'second line', 'third' }, path)
      vim.cmd.edit(path)
      vim.cmd.split()
      _G.client = h.ws_connect(cc.server.port, cc.harness.state.auth_token)

      local id = 0
      --- The next message Claude would receive, or nil when none was sent. A ping reply
      --- marks the end, since notifications go out before it.
      function _G.next_message()
        id = id + 1
        client:send_text(vim.json.encode({ jsonrpc = '2.0', id = id, method = 'ping' }))
        local msg = client:recv_json()
        if msg.id == id then
          return nil
        end
        h.eq(id, client:recv_json().id)
        return msg
      end

      function _G.keys(k)
        vim.api.nvim_feedkeys(vim.keycode(k), 'xt', false)
      end
    end)
  end)

  after_each(function()
    exec_lua(function()
      client:close()
      h.eq({}, h.stop_plugin(before), 'leaked handles')
    end)
  end)

  it('sends the file and cursor without text when leaving a file window', function()
    exec_lua(function()
      vim.api.nvim_win_set_cursor(0, { 2, 3 })
      vim.cmd.wincmd('w')
      local at = { line = 1, character = 3 }
      h.eq({
        jsonrpc = '2.0',
        method = 'selection_changed',
        params = {
          filePath = vim.api.nvim_buf_get_name(0),
          fileUrl = 'file://' .. vim.api.nvim_buf_get_name(0),
          selection = { start = at, ['end'] = at, isEmpty = true },
        },
      }, next_message())
    end)
  end)

  it('sends the text and 0-based range when leaving visual mode', function()
    exec_lua(function()
      local function sent(k)
        keys(k)
        local p = next_message().params
        return { p.text, p.selection.start, p.selection['end'] }
      end
      local function pos(line, character)
        return { line = line, character = character }
      end

      h.eq({ 'world\nsecond', pos(0, 6), pos(1, 6) }, sent('gg0wvjh<Esc>'))
      -- linewise ends at character 0 of the next line, which Claude reads as excluded
      h.eq({ 'second line\nthird', pos(1, 0), pos(3, 0) }, sent('ggjVj<Esc>'))
      h.eq({ 'ello\necon', pos(0, 1), pos(1, 5) }, sent('gg0l<C-v>j3l<Esc>'))
    end)
  end)

  it('keeps a visual selection when leaving the window right after it', function()
    exec_lua(function()
      keys('Vj<Esc>')
      h.eq('hello world\nsecond line', next_message().params.text)
      vim.cmd.wincmd('w')
      h.eq(nil, next_message())

      vim.cmd.wincmd('w')
      h.eq(true, next_message().params.selection.isEmpty)
      keys('Vj<Esc>')
      next_message()
      keys('k')
      vim.cmd.wincmd('w')
      h.eq(true, next_message().params.selection.isEmpty)
    end)
  end)

  it('sends the live selection when leaving a window in visual mode', function()
    exec_lua(function()
      keys('Vj')
      vim.cmd.wincmd('w')
      h.eq('hello world\nsecond line', next_message().params.text)
    end)
  end)

  it('sends nothing from terminals, help, or scratch buffers', function()
    exec_lua(function()
      cc.open()
      vim.cmd.wincmd('w')
      vim.cmd.enew()
      vim.bo.buftype = 'nofile'
      vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'a', 'b' })
      keys('Vj<Esc>')
      vim.cmd.help('help')
      keys('Vj<Esc>')
      vim.cmd.wincmd('w')
      h.eq(nil, next_message())
    end)
  end)

  it('sends nothing automatically when disabled, and on demand', function()
    exec_lua(function()
      cc.config.selection.auto = false
      keys('Vj<Esc>')
      vim.cmd.wincmd('w')
      h.eq(nil, next_message())

      cc.send_selection()
      h.eq('hello world\nsecond line', next_message().params.text)
    end)
  end)

  it('sends an at-mention with 0-based lines', function()
    exec_lua(function()
      cc.send_at_mention({ 2, 3 })
      h.eq({
        jsonrpc = '2.0',
        method = 'at_mentioned',
        params = { filePath = vim.api.nvim_buf_get_name(0), lineStart = 1, lineEnd = 2 },
      }, next_message())

      cc.send_at_mention()
      h.eq({ filePath = vim.api.nvim_buf_get_name(0) }, next_message().params)
    end)
  end)
end)
