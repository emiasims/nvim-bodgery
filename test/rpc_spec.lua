local helpers = require('test.helpers')
local exec_lua = require('nvim-test.helpers').exec_lua

describe('json-rpc and mcp', function()
  before_each(function()
    helpers.clear()
    exec_lua(function()
      _G.h = require('test.helpers')
      local mcp = require('claude-code.server.mcp')
      local ws = require('claude-code.server.ws')
      _G.before = h.handles()
      _G.cancelled = 0

      local d = mcp.new({
        name = 'test',
        tools = function()
          return {
            {
              name = 'add',
              description = 'adds',
              handler = function(args)
                return { sum = args.a + args.b }
              end,
            },
            {
              name = 'fails',
              description = 'raises',
              handler = function()
                error('nope', 0)
              end,
            },
          }
        end,
      })
      d:on('test/later', function(params)
        return function(resolve)
          vim.defer_fn(function()
            resolve({ v = params.v })
          end, params.ms)
          return function()
            cancelled = cancelled + 1
          end
        end
      end)

      _G.server = require('claude-code.server.http').start({
        auth = function(token)
          return token == 'good' and {} or nil
        end,
        routes = {
          mcp.http_route(d, '/mcp'),
          ws.route(vim.tbl_extend('force', mcp.ws_handlers(d), {
            path = '/',
            token = function()
              return 'ide-token'
            end,
          })),
        },
      })

      --- Posts a raw body to /mcp, initializing a session first unless `sid` is false.
      function _G.post(body, sid)
        if sid == nil then
          sid = h.request(server.port, 'POST', '/mcp', {
            token = 'good',
            body = { jsonrpc = '2.0', id = 0, method = 'initialize', params = {} },
          }).headers['mcp-session-id']
        end
        return h.request(server.port, 'POST', '/mcp', {
          token = 'good',
          body = body,
          headers = { ['Mcp-Session-Id'] = sid or nil },
        })
      end
    end)
  end)

  after_each(function()
    exec_lua(function()
      server:stop()
      h.eq({}, h.leaked(before), 'leaked handles')
    end)
  end)

  it('gives the same result over HTTP and the websocket', function()
    exec_lua(function()
      local cases = {
        { jsonrpc = '2.0', id = 1, method = 'initialize', params = { protocolVersion = '2025-03-26' } },
        { jsonrpc = '2.0', id = 2, method = 'ping' },
        { jsonrpc = '2.0', id = 3, method = 'tools/list' },
        {
          jsonrpc = '2.0',
          id = 4,
          method = 'tools/call',
          params = { name = 'add', arguments = { a = 1, b = 2 } },
        },
        { jsonrpc = '2.0', id = 5, method = 'tools/call', params = { name = 'fails', arguments = {} } },
        { jsonrpc = '2.0', id = 6, method = 'tools/call', params = { name = 'missing' } },
        { jsonrpc = '2.0', id = 7, method = 'no/such' },
        { jsonrpc = '1.0', id = 8, method = 'ping' },
        '{"jsonrpc":',
      }
      local expected = {
        {
          protocolVersion = '2025-03-26',
          capabilities = { tools = {} },
          serverInfo = { name = 'test', version = '0.1.0' },
        },
        {},
        {
          tools = {
            { name = 'add', description = 'adds', inputSchema = { type = 'object', properties = {} } },
            { name = 'fails', description = 'raises', inputSchema = { type = 'object', properties = {} } },
          },
        },
        { content = { { type = 'text', text = '{"sum":3}' } } },
        { content = { { type = 'text', text = 'nope' } }, isError = true },
        -32602,
        -32601,
        -32600,
        -32700,
      }

      local c = h.ws_connect(server.port, 'ide-token')
      for i, case in ipairs(cases) do
        local raw = type(case) == 'string' and case or vim.json.encode(case)
        local http_res = post(raw).json
        c:send_text(raw)
        local ws_res = c:recv_json()
        h.eq(http_res, ws_res, 'case ' .. i)
        if type(expected[i]) == 'number' then
          h.eq(expected[i], ws_res.error.code, 'case ' .. i)
        else
          h.eq(expected[i], ws_res.result, 'case ' .. i)
        end
      end
      c:close()
    end)
  end)

  it('sends no reply to a notification', function()
    exec_lua(function()
      local res = post({ jsonrpc = '2.0', method = 'notifications/initialized' })
      h.eq(202, res.status)
      h.eq('', res.body)

      local c = h.ws_connect(server.port, 'ide-token')
      c:send_text(vim.json.encode({ jsonrpc = '2.0', method = 'notifications/initialized' }))
      c:send_text(vim.json.encode({ jsonrpc = '2.0', method = 'no/such/notification' }))
      c:send_text(vim.json.encode({ jsonrpc = '2.0', id = 1, method = 'ping' }))
      h.eq(1, c:recv_json().id)
      c:close()
    end)
  end)

  it('resolves a deferred reply after later requests were answered', function()
    exec_lua(function()
      local c = h.ws_connect(server.port, 'ide-token')
      c:send_text(
        vim.json.encode({ jsonrpc = '2.0', id = 1, method = 'test/later', params = { v = 'a', ms = 50 } })
      )
      c:send_text(vim.json.encode({ jsonrpc = '2.0', id = 2, method = 'ping' }))
      h.eq(2, c:recv_json().id)
      h.eq({ jsonrpc = '2.0', id = 1, result = { v = 'a' } }, c:recv_json())
      c:close()

      -- over HTTP the response waits for the resolve
      local res = post({ jsonrpc = '2.0', id = 3, method = 'test/later', params = { v = 'b', ms = 20 } })
      h.eq({ v = 'b' }, res.json.result)
    end)
  end)

  it('drops pending replies when the connection closes', function()
    exec_lua(function()
      local c = h.ws_connect(server.port, 'ide-token')
      c:send_text(
        vim.json.encode({ jsonrpc = '2.0', id = 1, method = 'test/later', params = { v = 'a', ms = 50 } })
      )
      vim.wait(10)
      c:close()
      h.wait(function()
        return cancelled == 1
      end, 'cancel')
      -- the timer resolves into a closed connection
      vim.wait(80)
    end)
  end)

  it('refuses a missing or unknown Mcp-Session-Id after initialize', function()
    exec_lua(function()
      local ping = { jsonrpc = '2.0', id = 1, method = 'ping' }
      h.eq(400, post(ping, false).status)
      h.eq(404, post(ping, 'made-up').status)
      h.eq(200, post(ping).status)
      h.eq(405, h.request(server.port, 'GET', '/mcp', { token = 'good' }).status)
    end)
  end)
end)
