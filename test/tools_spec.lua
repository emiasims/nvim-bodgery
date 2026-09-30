local helpers = require('test.helpers')
local exec_lua = require('nvim-test.helpers').exec_lua

describe('custom tools', function()
  before_each(function()
    helpers.clear()
    exec_lua(function()
      _G.h = require('test.helpers')
      _G.before = h.handles()
      _G.cc = require('bodgery')
      cc.setup({ cmd = h.fake_cmd() })
      cc.start('claude')
      _G.help = require('bodgery.tools.help')

      local id = 0
      --- Posts one JSON-RPC request to /mcp with a terminal's token.
      local function post(token, method, params, sid)
        id = id + 1
        return h.request(cc.server.port, 'POST', '/mcp', {
          token = token,
          body = { jsonrpc = '2.0', id = id, method = method, params = params },
          headers = { ['Mcp-Session-Id'] = sid },
        })
      end

      --- An MCP session for the terminal in `bufnr`, the way Claude opens one.
      function _G.session(bufnr)
        local token = require('bodgery.terminal').terminals[bufnr].token
        local sid = post(token, 'initialize', vim.empty_dict()).headers['mcp-session-id']
        return {
          names = function()
            return vim.tbl_map(function(t)
              return t.name
            end, post(token, 'tools/list', nil, sid).json.result.tools)
          end,
          call = function(name, args)
            return post(token, 'tools/call', { name = name, arguments = args }, sid).json.result
          end,
        }
      end
    end)
  end)

  after_each(function()
    exec_lua(function()
      h.eq({}, h.stop_plugin(before), 'leaked handles')
    end)
  end)

  it('lists a tool registered after initialize', function()
    exec_lua(function()
      local s = session(cc.open('claude'))
      local builtin = {
        'nvim_buffers',
        'nvim_help',
        'nvim_help_search',
        'nvim_helpgrep',
        'nvim_messages',
        'nvim_quickfix',
        'nvim_rpc_read',
        'nvim_rpc_write',
        'nvim_screen',
      }
      h.eq(builtin, s.names())
      cc.tool('late', {
        description = 'registered mid-session',
        handler = function()
          return { ok = true }
        end,
      })
      h.eq({ 'late', unpack(builtin) }, s.names())
      h.eq({ content = { { type = 'text', text = '{"ok":true}' } } }, s.call('late', {}))
    end)
  end)

  it("passes each call the calling terminal's session and buffer", function()
    exec_lua(function()
      cc.tool('whoami', {
        description = 'returns ctx',
        handler = function(_, ctx)
          return ctx
        end,
      })
      local a, b = cc.open('claude'), cc.open('claude')
      local terms = require('bodgery.terminal').terminals
      h.post_hook(cc.server.port, terms[a].token, h.fixture('SessionStart-startup', { session_id = 'sa' }))
      h.post_hook(cc.server.port, terms[b].token, h.fixture('SessionStart-startup', { session_id = 'sb' }))

      local function whoami(bufnr)
        return vim.json.decode(session(bufnr).call('whoami', {}).content[1].text)
      end
      h.eq({ session_id = 'sa', bufnr = a }, whoami(a))
      h.eq({ session_id = 'sb', bufnr = b }, whoami(b))
    end)
  end)

  it('returns a help section up to the next tag', function()
    exec_lua(function()
      local text = help.help('nvim_buf_get_lines()')
      local lines = vim.split(text, '\n')
      assert(lines[1]:find('*nvim_buf_get_lines()*', 1, true), lines[1])
      assert(text:find('Gets a line%-range'), text)
      for i = 2, #lines do
        assert(not lines[i]:find('%*[^%s%*|]+%*'), 'tag inside the section: ' .. lines[i])
      end

      vim.opt.runtimepath:append(h.root .. '/test/fixtures/helpdoc')
      local s = session(cc.open('claude'))
      h.eq({
        content = {
          {
            type = 'text',
            text = table.concat({
              '1. Alpha\t\t\t\t\t\t*fixture-alpha*',
              '\t\t\t\t\t\t\t*fixture-alpha-alias*',
              'Alpha text one.',
              'Alpha text two.',
            }, '\n'),
          },
        },
      }, s.call('nvim_help', { tag = 'fixture-alpha' }))
    end)
  end)

  it('reports an unknown tag as an error with the closest tags', function()
    exec_lua(function()
      local res = session(cc.open('claude')).call('nvim_help', { tag = 'nvim_buf_get_line' })
      h.eq(true, res.isError)
      assert(res.content[1].text:find('nvim_buf_get_lines()', 1, true), res.content[1].text)
    end)
  end)

  it("searches plugin help on 'runtimepath' and stops at the cap", function()
    exec_lua(function()
      vim.opt.runtimepath:append(h.root .. '/test/fixtures/helpdoc')
      help.max_results = 2
      local s = session(cc.open('claude'))
      local function text(name, pattern)
        return s.call(name, { pattern = pattern }).content[1].text
      end

      h.eq(
        'fixture-alpha  (fixture.txt)\nfixture-alpha-alias  (fixture.txt)\n(1 more not shown)',
        text('nvim_help_search', '^fixture-')
      )
      h.eq(
        'fixture.txt:12 [fixture-beta] Beta text. fixturegrep 1\n'
          .. 'fixture.txt:13 [fixture-beta] fixturegrep 2\n(1 more not shown)',
        text('nvim_helpgrep', 'fixturegrep')
      )
      h.eq('no matching tags', text('nvim_help_search', '^no-such-tag-anywhere$'))
    end)
  end)

  it('leaves the quickfix list alone', function()
    exec_lua(function()
      vim.fn.setqflist({}, ' ', { title = 'mine', items = { { filename = 'x', lnum = 1, text = 't' } } })
      local before_qf = vim.fn.getqflist({ all = true })
      local res = session(cc.open('claude')).call('nvim_helpgrep', { pattern = 'nvim_buf_get_lines' })
      h.eq(nil, res.isError)
      h.eq(before_qf, vim.fn.getqflist({ all = true }))
      h.eq(1, vim.fn.getqflist({ nr = '$' }).nr)
    end)
  end)
end)
