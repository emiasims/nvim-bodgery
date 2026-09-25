local helpers = require('test.helpers')
local exec_lua = require('nvim-test.helpers').exec_lua

describe('sha1', function()
  before_each(helpers.clear)

  it('matches the FIPS 180 vectors', function()
    exec_lua(function()
      local h = require('test.helpers')
      local sha1 = require('claude-code.server.sha1')
      local function hex(s)
        return (s:gsub('.', function(c)
          return ('%02x'):format(c:byte())
        end))
      end
      h.eq('da39a3ee5e6b4b0d3255bfef95601890afd80709', hex(sha1('')))
      h.eq('a9993e364706816aba3e25717850c26c9cd0d89d', hex(sha1('abc')))
      h.eq('34aa973cd4c4daa4f61eeb2bdbad27316534016f', hex(sha1(('a'):rep(1000000))))
    end)
  end)

  it("gives RFC 6455's accept key", function()
    exec_lua(function()
      local h = require('test.helpers')
      h.eq(
        's3pPLMBiTxaQ9kYGzzhZRbK+xOo=',
        require('claude-code.server.ws').accept_key('dGhlIHNhbXBsZSBub25jZQ==')
      )
    end)
  end)
end)

describe('websocket', function()
  before_each(function()
    helpers.clear()
    exec_lua(function()
      _G.h = require('test.helpers')
      _G.ws = require('claude-code.server.ws')
      _G.before = h.handles()
      _G.received = {}
      _G.closed = 0
      _G.server = require('claude-code.server.http').start({
        auth = function() end,
        routes = {
          ws.route({
            path = '/',
            token = function()
              return 'secret-token'
            end,
            on_message = function(conn, text)
              received[#received + 1] = text
              conn:send('echo:' .. text)
            end,
            on_close = function()
              closed = closed + 1
            end,
          }),
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

  it('upgrades with the mcp subprotocol', function()
    exec_lua(function()
      local c, res = h.ws_connect(server.port, 'secret-token')
      h.eq(101, res.status)
      h.eq('s3pPLMBiTxaQ9kYGzzhZRbK+xOo=', res.headers['sec-websocket-accept'])
      h.eq('mcp', res.headers['sec-websocket-protocol'])
      c:close()
    end)
  end)

  it('refuses a missing or wrong token with 401 before the upgrade', function()
    exec_lua(function()
      local c, res = h.ws_connect(server.port)
      h.eq(401, res.status)
      c:close()
      c, res = h.ws_connect(server.port, 'wrong')
      h.eq(401, res.status)
      c:close()
    end)
  end)

  it('reads masked text frames of each length encoding split across reads', function()
    exec_lua(function()
      local c = h.ws_connect(server.port, 'secret-token')
      local texts = { ('a'):rep(5), ('b'):rep(300), ('c'):rep(70000) }
      -- the 64-bit frame arrives in two writes, the others a byte at a time
      c:send_frame(ws.OP.TEXT, texts[1], 1)
      c:send_frame(ws.OP.TEXT, texts[2], 0)
      local big = ws.encode(ws.OP.TEXT, texts[3], 'wxyz')
      c:send(big:sub(1, 7))
      vim.wait(10)
      c:send(big:sub(8))
      for _, text in ipairs(texts) do
        local frame = c:recv()
        h.eq(ws.OP.TEXT, frame.opcode)
        h.eq('echo:' .. text, frame.payload)
      end
      h.eq(texts, received)
      c:close()
    end)
  end)

  it('answers a ping with a pong and a close with a close', function()
    exec_lua(function()
      local c = h.ws_connect(server.port, 'secret-token')
      c:send_frame(ws.OP.PING, 'hi')
      local pong = c:recv()
      h.eq({ ws.OP.PONG, 'hi' }, { pong.opcode, pong.payload })
      c:send_frame(ws.OP.CLOSE, string.char(0x03, 0xE8))
      local close = c:recv()
      h.eq({ ws.OP.CLOSE, 1000 }, { close.opcode, h.close_code(close) })
      c:wait_eof()
      h.wait(function()
        return closed == 1
      end, 'on_close')
      c:close()
    end)
  end)

  it('closes with 1002 on an unmasked frame and 1003 on a continuation', function()
    exec_lua(function()
      local c = h.ws_connect(server.port, 'secret-token')
      c:send(ws.encode(ws.OP.TEXT, 'plain'))
      h.eq(1002, h.close_code(c:recv()))
      c:wait_eof()
      c:close()

      c = h.ws_connect(server.port, 'secret-token')
      c:send_frame(ws.OP.CONTINUATION, 'more')
      h.eq(1003, h.close_code(c:recv()))
      c:wait_eof()
      c:close()
      h.eq({}, received)
    end)
  end)
end)
