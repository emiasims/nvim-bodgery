local helpers = require('test.helpers')
local exec_lua = require('nvim-test.helpers').exec_lua

describe('http server', function()
  before_each(function()
    helpers.clear()
    exec_lua(function()
      _G.h = require('test.helpers')
      _G.http = require('bodging.server.http')
      _G.before = h.handles()
      _G.calls = {}
      _G.server = http.start({
        max_body = 1024,
        auth = function(token)
          return ({ good = { name = 'term1' } })[token]
        end,
        routes = {
          {
            method = 'POST',
            path = '/echo',
            handler = function(req)
              calls[#calls + 1] = req.body
              return 200, { body = req.body, ctx = req.ctx, method = req.method }
            end,
          },
          {
            method = 'GET',
            path = '/open',
            public = true,
            handler = function()
              return 200, { ok = true }
            end,
          },
          {
            method = 'POST',
            path = '/boom',
            handler = function()
              error('boom')
            end,
          },
          {
            method = 'POST',
            path = '/later',
            handler = function(req, respond)
              vim.defer_fn(function()
                respond(200, { body = req.body })
              end, 50)
            end,
          },
        },
      })
    end)
  end)

  after_each(function()
    exec_lua(function()
      server:stop()
      h.eq({}, h.leaked(before), 'leaked handles')
    end)
  end)

  it('parses a request delivered one byte per write', function()
    exec_lua(function()
      local c = h.connect(server.port)
      c:send(h.format_request('POST', '/echo', { token = 'good', body = 'hello' }), 2)
      local res = c:read()
      c:close()
      h.eq(200, res.status)
      h.eq({ body = 'hello', ctx = { name = 'term1' }, method = 'POST' }, res.json)
    end)
  end)

  it('reads Content-Length and chunked bodies', function()
    exec_lua(function()
      local res = h.request(server.port, 'POST', '/echo', { token = 'good', body = '{"a":1}' })
      h.eq('{"a":1}', res.json.body)

      local c = h.connect(server.port)
      local head = h.format_request('POST', '/echo', {
        token = 'good',
        headers = { ['Transfer-Encoding'] = 'chunked' },
      })
      c:send(head .. '5;ext=1\r\nhello\r\n')
      vim.wait(10)
      c:send('7\r\n, world\r\n0\r\nX-Trailer: 1\r\n\r\n')
      res = c:read()
      c:close()
      h.eq('hello, world', res.json.body)
    end)
  end)

  it('answers two requests on one connection in order', function()
    exec_lua(function()
      local c = h.connect(server.port)
      c:send(
        h.format_request('POST', '/later', { token = 'good', body = 'first' })
          .. h.format_request('POST', '/echo', { token = 'good', body = 'second' })
      )
      local a, b = c:read(), c:read()
      c:close()
      h.eq('first', a.json.body)
      h.eq('second', b.json.body)
    end)
  end)

  it('refuses bad requests with the right status', function()
    exec_lua(function()
      local p = server.port
      h.eq(401, h.request(p, 'POST', '/echo', { body = 'x' }).status)
      h.eq(401, h.request(p, 'POST', '/echo', { token = 'bad', body = 'x' }).status)
      h.eq(404, h.request(p, 'POST', '/nope', { token = 'good' }).status)
      h.eq(405, h.request(p, 'GET', '/echo', { token = 'good' }).status)
      h.eq(413, h.request(p, 'POST', '/echo', { token = 'good', body = ('x'):rep(1025) }).status)
      h.eq(200, h.request(p, 'GET', '/open').status)
      h.eq({}, calls)
    end)
  end)

  it('answers 500 when a handler raises and keeps serving', function()
    exec_lua(function()
      local c = h.connect(server.port)
      c:send(h.format_request('POST', '/boom', { token = 'good' }))
      local res = c:read()
      h.eq(500, res.status)
      assert(res.json.error:find('boom'), res.body)
      c:send(h.format_request('POST', '/echo', { token = 'good', body = 'next' }))
      h.eq('next', c:read().json.body)
      c:close()
    end)
  end)

  it('closes the listener and every client on stop()', function()
    exec_lua(function()
      local idle = h.connect(server.port)
      local pending = h.connect(server.port)
      pending:send(h.format_request('POST', '/later', { token = 'good', body = 'x' }))
      vim.wait(10)
      server:stop()
      idle:wait_eof()
      pending:wait_eof()
      idle:close()
      pending:close()
      local refused
      vim.uv.new_tcp():connect('127.0.0.1', server.port, function(err)
        refused = err
      end)
      h.wait(function()
        return refused
      end, 'refused connection')
      -- the test's own failed socket is still open
      vim.uv.walk(function(handle)
        if not handle:is_closing() and handle:get_type() == 'tcp' then
          handle:close()
        end
      end)
    end)
  end)
end)
