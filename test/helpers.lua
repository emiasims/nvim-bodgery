-- Loaded in both processes: `clear()` in the test runner, the clients inside the child
-- Neovim through `require('test.helpers')`.
local M = {}

local TIMEOUT = 2000

--- Starts a fresh child Neovim that can require the plugin and these helpers.
function M.clear()
  local t = require('nvim-test.helpers')
  t.clear()
  t.exec_lua('package.path = ...', package.path)
end

--- @param expected any
--- @param actual any
--- @param msg? string
function M.eq(expected, actual, msg)
  if not vim.deep_equal(expected, actual) then
    error(
      ('%s\n\nactual: %s\n\nexpected: %s'):format(
        msg or 'Mismatch:',
        vim.inspect(actual),
        vim.inspect(expected)
      ),
      2
    )
  end
end

--- @param cond fun(): any
--- @param msg string
function M.wait(cond, msg)
  if not vim.wait(TIMEOUT, cond, 1) then
    error('timed out: ' .. msg, 2)
  end
end

--- Types of every open libuv handle, for leak checks.
--- @return table<userdata, string>
function M.handles()
  local out = {}
  vim.uv.walk(function(h)
    if not h:is_closing() then
      out[h] = h:get_type()
    end
  end)
  return out
end

--- @param before table<userdata, string> from `handles()`
--- @return string[] types of handles opened since `before` that are still open
function M.leaked(before)
  local out
  -- let close callbacks and pending timers finish
  vim.wait(500, function()
    out = {}
    for h, kind in pairs(M.handles()) do
      if not before[h] then
        out[#out + 1] = kind
      end
    end
    return #out == 0
  end, 5)
  return out
end

--- @class test.Response
--- @field status integer
--- @field headers table<string, string>
--- @field body string
--- @field json? any

--- @class test.Client
--- @field tcp uv.uv_tcp_t
--- @field buf string
--- @field eof boolean
local Client = {}
Client.__index = Client

--- @param port integer
--- @return test.Client
function M.connect(port)
  local self = setmetatable({ tcp = assert(vim.uv.new_tcp()), buf = '', eof = false }, Client)
  local connected = false
  self.tcp:connect('127.0.0.1', port, function(err)
    assert(not err, err)
    connected = true
    self.tcp:read_start(function(rerr, data)
      if rerr or not data then
        self.eof = true
      else
        self.buf = self.buf .. data
      end
    end)
  end)
  M.wait(function()
    return connected
  end, 'connect')
  self.tcp:nodelay(true)
  return self
end

--- Writes `data`. With `step`, writes one byte at a time and waits `step` ms between writes
--- so each byte arrives in its own read.
--- @param data string
--- @param step? integer
function Client:send(data, step)
  if not step then
    self.tcp:write(data)
    return
  end
  for i = 1, #data do
    self.tcp:write(data:sub(i, i))
    vim.wait(step)
  end
end

--- Waits for the next complete response.
--- @return test.Response
function Client:read()
  local res
  M.wait(function()
    local head_end = self.buf:find('\r\n\r\n', 1, true)
    if not head_end then
      return self.eof
    end
    local lines = vim.split(self.buf:sub(1, head_end - 1), '\r\n', { plain = true })
    local headers = {}
    for i = 2, #lines do
      local name, value = lines[i]:match('^([^:]+):%s*(.*)$')
      headers[name:lower()] = value
    end
    local len = tonumber(headers['content-length'] or '0')
    if #self.buf < head_end + 3 + len then
      return self.eof
    end
    res = {
      status = tonumber(lines[1]:match('^HTTP/1%.1 (%d+)')),
      headers = headers,
      body = self.buf:sub(head_end + 4, head_end + 3 + len),
    }
    self.buf = self.buf:sub(head_end + 4 + len)
    local ok, json = pcall(vim.json.decode, res.body)
    res.json = ok and json or nil
    return true
  end, 'response')
  assert(res, 'connection closed before a response')
  return res
end

--- Waits for the server to close the connection.
function Client:wait_eof()
  M.wait(function()
    return self.eof
  end, 'eof')
end

function Client:close()
  if not self.tcp:is_closing() then
    self.tcp:close()
  end
end

--- @class test.RequestOpts
--- @field headers? table<string, string>
--- @field body? string|table table bodies are JSON-encoded
--- @field token? string sent as a bearer token

--- @param method string
--- @param path string
--- @param opts? test.RequestOpts
--- @return string
function M.format_request(method, path, opts)
  opts = opts or {}
  local body = opts.body
  if type(body) == 'table' then
    body = vim.json.encode(body)
  end
  local headers = vim.tbl_extend('force', { Host = '127.0.0.1' }, opts.headers or {})
  if opts.token then
    headers.Authorization = 'Bearer ' .. opts.token
  end
  if body and not headers['Transfer-Encoding'] then
    headers['Content-Length'] = tostring(#body)
  end
  local lines = { ('%s %s HTTP/1.1'):format(method, path) }
  for name, value in pairs(headers) do
    lines[#lines + 1] = name .. ': ' .. value
  end
  return table.concat(lines, '\r\n') .. '\r\n\r\n' .. (body or '')
end

--- One request on a fresh connection.
--- @param port integer
--- @param method string
--- @param path string
--- @param opts? test.RequestOpts
--- @return test.Response
function M.request(port, method, path, opts)
  local client = M.connect(port)
  client:send(M.format_request(method, path, opts))
  local res = client:read()
  client:close()
  return res
end

--- Sends a websocket upgrade request and returns the client and the server's response.
--- @param port integer
--- @param token? string `X-Claude-Code-Ide-Authorization`
--- @param path? string default '/'
--- @return test.Client
--- @return test.Response
function M.ws_connect(port, token, path)
  local client = M.connect(port)
  client:send(M.format_request('GET', path or '/', {
    headers = {
      Upgrade = 'websocket',
      Connection = 'Upgrade',
      ['Sec-WebSocket-Key'] = 'dGhlIHNhbXBsZSBub25jZQ==',
      ['Sec-WebSocket-Version'] = '13',
      ['Sec-WebSocket-Protocol'] = 'mcp',
      ['X-Claude-Code-Ide-Authorization'] = token,
    },
  }))
  return client, client:read()
end

--- Sends one masked frame. See `Client:send` for `step`.
--- @param opcode integer
--- @param payload string
--- @param step? integer
function Client:send_frame(opcode, payload, step)
  self:send(require('claude-code.server.ws').encode(opcode, payload, 'abcd'), step)
end

--- @param text string
function Client:send_text(text)
  self:send_frame(require('claude-code.server.ws').OP.TEXT, text)
end

--- Waits for the next frame from the server.
--- @return claude-code.ws.Frame
function Client:recv()
  local ws = require('claude-code.server.ws')
  local frame
  M.wait(function()
    local f, consumed = ws.decode(self.buf)
    if f then
      frame = f
      self.buf = self.buf:sub(consumed + 1)
      return true
    end
    return self.eof
  end, 'frame')
  assert(frame, 'connection closed before a frame')
  return frame
end

--- Waits for the next text frame and decodes it as JSON.
--- @return any
function Client:recv_json()
  local frame = self:recv()
  assert(frame.opcode == 0x1, 'expected a text frame, got opcode ' .. frame.opcode)
  return vim.json.decode(frame.payload)
end

--- @param frame claude-code.ws.Frame
--- @return integer
function M.close_code(frame)
  return frame.payload:byte(1) * 256 + frame.payload:byte(2)
end

return M
