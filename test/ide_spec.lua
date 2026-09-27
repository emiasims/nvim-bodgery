local helpers = require('test.helpers')
local exec_lua = require('nvim-test.helpers').exec_lua

describe('ide tools', function()
  before_each(function()
    helpers.clear()
    exec_lua(function()
      _G.h = require('test.helpers')
      _G.before = h.handles()
      _G.cc = require('bodging')
      cc.setup({
        cmd = h.fake_cmd(),
        tools = {
          custom = {
            description = 'a custom tool',
            handler = function()
              return 'hi'
            end,
          },
        },
      })
      cc.start('claude')
      _G.dir = vim.fn.tempname()
      vim.fn.mkdir(dir, 'p')

      local id = 0
      --- Calls an IDE tool over a fresh websocket and returns its MCP result.
      function _G.call(name, args)
        local c = h.ws_connect(cc.server.port, cc.harnesses.claude.state.auth_token)
        id = id + 1
        c:send_text(vim.json.encode({
          jsonrpc = '2.0',
          id = id,
          method = 'tools/call',
          params = { name = name, arguments = args or vim.empty_dict() },
        }))
        local res = c:recv_json()
        c:close()
        return res.result or res.error
      end

      --- getDiagnostics decoded.
      function _G.diagnostics(uri)
        return vim.json.decode(call('getDiagnostics', uri and { uri = uri } or nil).content[1].text)
      end

      --- Opens `name` in `dir` with `lines` in a new loaded buffer.
      function _G.open(name, lines)
        local path = dir .. '/' .. name
        vim.fn.writefile(lines, path)
        vim.cmd.edit(path)
        return vim.api.nvim_get_current_buf(), path
      end
    end)
  end)

  after_each(function()
    exec_lua(function()
      h.eq({}, h.stop_plugin(before), 'leaked handles')
    end)
  end)

  it('returns vim.diagnostic entries with severity names and 0-based ranges', function()
    exec_lua(function()
      local bufnr, path = open('a.txt', { 'one', 'two' })
      local ns = vim.api.nvim_create_namespace('test')
      vim.diagnostic.set(ns, bufnr, {
        {
          lnum = 1,
          col = 0,
          end_lnum = 1,
          end_col = 3,
          severity = vim.diagnostic.severity.WARN,
          message = 'w',
          source = 'lsp',
          code = 42,
        },
        { lnum = 0, col = 1, severity = vim.diagnostic.severity.ERROR, message = 'e' },
      })
      local got = diagnostics('file://' .. path)
      h.eq(1, #got)
      h.eq('file://' .. path, got[1].uri)
      table.sort(got[1].diagnostics, function(a, b)
        return a.message < b.message
      end)
      h.eq({
        {
          message = 'e',
          severity = 'Error',
          range = { start = { line = 0, character = 1 }, ['end'] = { line = 0, character = 1 } },
        },
        {
          message = 'w',
          severity = 'Warning',
          source = 'lsp',
          code = '42',
          range = { start = { line = 1, character = 0 }, ['end'] = { line = 1, character = 3 } },
        },
      }, got[1].diagnostics)
    end)
  end)

  it('reports treesitter syntax errors, and none without a parser', function()
    exec_lua(function()
      local _, lua_path = open('bad.lua', { 'local x = (' })
      local got = diagnostics('file://' .. lua_path)[1].diagnostics
      assert(#got > 0, 'expected syntax errors')
      for _, d in ipairs(got) do
        h.eq({ 'treesitter', 'Error' }, { d.source, d.severity })
      end

      local _, txt_path = open('plain.txt', { 'local x = (' })
      h.eq({}, diagnostics('file://' .. txt_path)[1].diagnostics)
    end)
  end)

  it('returns an empty list for a file that is not loaded', function()
    exec_lua(function()
      local res = call('getDiagnostics', { uri = 'file://' .. dir .. '/never-opened.lua' })
      h.eq(nil, res.isError)
      h.eq('[]', res.content[1].text)
    end)
  end)

  it('covers loaded buffers only when called without arguments', function()
    exec_lua(function()
      local ns = vim.api.nvim_create_namespace('test')
      local loaded, loaded_path = open('loaded.txt', { 'x' })
      vim.diagnostic.set(ns, loaded, { { lnum = 0, col = 0, message = 'here' } })
      vim.fn.writefile({ 'y' }, dir .. '/unloaded.txt')
      local unloaded = vim.fn.bufadd(dir .. '/unloaded.txt')
      vim.diagnostic.set(ns, unloaded, { { lnum = 0, col = 0, message = 'hidden' } })
      h.eq(false, vim.api.nvim_buf_is_loaded(unloaded))

      local uris = vim.tbl_map(function(f)
        return f.uri
      end, diagnostics())
      h.eq({ 'file://' .. vim.uv.fs_realpath(loaded_path) }, uris)
    end)
  end)

  it('serves executeCode only when enabled', function()
    exec_lua(function()
      cc.open('claude', { mods = {} })
      local function names()
        local c = h.ws_connect(cc.server.port, cc.harnesses.claude.state.auth_token)
        c:send_text(vim.json.encode({ jsonrpc = '2.0', id = 1, method = 'tools/list' }))
        local list = vim.tbl_map(function(t)
          return t.name
        end, c:recv_json().result.tools)
        c:close()
        return list
      end
      local ide_tools = { 'getDiagnostics', 'openDiff', 'close_tab', 'closeAllDiffTabs' }
      h.eq(ide_tools, names())
      h.eq(-32602, call('executeCode', { code = 'return 1' }).code)

      cc.configs.claude.execute_code = true
      h.eq(vim.list_extend(vim.list_slice(ide_tools), { 'executeCode' }), names())
      h.eq('3\n"x"', call('executeCode', { code = 'return 1 + 2, "x"' }).content[1].text)
      h.eq('nil', call('executeCode', { code = 'local _ = 1' }).content[1].text)
      local err = call('executeCode', { code = 'error("bad")' })
      h.eq(true, err.isError)
      assert(err.content[1].text:find('bad'), err.content[1].text)
      h.eq(true, call('executeCode', { code = 'return (' }).isError)
    end)
  end)

  it('keeps IDE tools on the websocket and custom tools on /mcp', function()
    exec_lua(function()
      local c = h.ws_connect(cc.server.port, cc.harnesses.claude.state.auth_token)
      c:send_text(vim.json.encode({ jsonrpc = '2.0', id = 1, method = 'tools/list' }))
      local ws_names = vim.tbl_map(function(t)
        return t.name
      end, c:recv_json().result.tools)
      c:close()
      h.eq({ 'getDiagnostics', 'openDiff', 'close_tab', 'closeAllDiffTabs' }, ws_names)

      local token = require('bodging.terminal').terminals[cc.open('claude')].token
      local function post(body, sid)
        return h.request(cc.server.port, 'POST', '/mcp', {
          token = token,
          body = body,
          headers = { ['Mcp-Session-Id'] = sid },
        })
      end
      local sid =
        post({ jsonrpc = '2.0', id = 1, method = 'initialize', params = {} }).headers['mcp-session-id']
      local mcp_names = vim.tbl_map(function(t)
        return t.name
      end, post({ jsonrpc = '2.0', id = 2, method = 'tools/list' }, sid).json.result.tools)
      h.eq({ 'custom', 'nvim_help', 'nvim_help_search', 'nvim_helpgrep', 'nvim_screen' }, mcp_names)
    end)
  end)
end)
