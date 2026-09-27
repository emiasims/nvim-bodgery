-- Websocket upgrade and frames (RFC 6455). Frame parsing and building adapted from
-- claudecode.nvim's server/frame.lua (https://github.com/coder/claudecode.nvim, commit 2390c6e,
-- MIT License, Copyright (c) 2025 Coder Technologies).
local bit = require('bit')
local http = require('bodgery.server.http')
local sha1 = require('bodgery.server.sha1')

local M = {}

M.OP = { CONTINUATION = 0x0, TEXT = 0x1, BINARY = 0x2, CLOSE = 0x8, PING = 0x9, PONG = 0xA }

local MAX_PAYLOAD = 100 * 1024 * 1024
local GUID = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11'

--- @param data string
--- @param mask string 4 bytes
local function apply_mask(data, mask)
  local m = { mask:byte(1, 4) }
  local out = {}
  for i = 1, #data do
    out[i] = string.char(bit.bxor(data:byte(i), m[(i - 1) % 4 + 1]))
  end
  return table.concat(out)
end

--- @param n integer
--- @param bytes integer
local function uint(n, bytes)
  local out = {}
  for i = bytes, 1, -1 do
    out[i] = string.char(n % 256)
    n = math.floor(n / 256)
  end
  return table.concat(out)
end

--- @param opcode integer
--- @param payload string
--- @param mask? string 4 bytes; clients must mask, servers must not
--- @return string
function M.encode(opcode, payload, mask)
  local len = #payload
  local mask_bit = mask and 0x80 or 0
  local head
  if len < 126 then
    head = string.char(0x80 + opcode, mask_bit + len)
  elseif len < 65536 then
    head = string.char(0x80 + opcode, mask_bit + 126) .. uint(len, 2)
  else
    head = string.char(0x80 + opcode, mask_bit + 127) .. uint(len, 8)
  end
  if mask then
    return head .. mask .. apply_mask(payload, mask)
  end
  return head .. payload
end

--- @class bodgery.ws.Frame
--- @field fin boolean
--- @field opcode integer
--- @field masked boolean
--- @field payload string unmasked

--- Parses one frame from the front of `buf`.
--- @param buf string
--- @return bodgery.ws.Frame? frame nil when incomplete or invalid
--- @return integer consumed bytes
--- @return integer? close_code set when the frame violates the protocol
function M.decode(buf)
  if #buf < 2 then
    return nil, 0
  end
  local b1, b2 = buf:byte(1, 2)
  local fin = b1 >= 0x80
  local opcode = b1 % 16
  local masked = b2 >= 0x80
  local len = b2 % 128
  local pos = 3

  if bit.band(b1, 0x70) ~= 0 then
    return nil, 0, 1002
  end
  if not ((opcode <= 0x2) or (opcode >= 0x8 and opcode <= 0xA)) then
    return nil, 0, 1002
  end
  if opcode >= 0x8 and (not fin or len > 125) then
    return nil, 0, 1002
  end

  local ext = len == 126 and 2 or len == 127 and 8 or 0
  if #buf < pos + ext - 1 then
    return nil, 0
  end
  if ext > 0 then
    len = 0
    for i = pos, pos + ext - 1 do
      len = len * 256 + buf:byte(i)
    end
    pos = pos + ext
  end
  if len > MAX_PAYLOAD then
    return nil, 0, 1009
  end

  local mask
  if masked then
    if #buf < pos + 3 then
      return nil, 0
    end
    mask = buf:sub(pos, pos + 3)
    pos = pos + 4
  end
  if #buf < pos + len - 1 then
    return nil, 0
  end

  local payload = buf:sub(pos, pos + len - 1)
  if mask then
    payload = apply_mask(payload, mask)
  end
  return { fin = fin, opcode = opcode, masked = masked, payload = payload }, pos + len - 1
end

--- @param key string `Sec-WebSocket-Key`
--- @return string
function M.accept_key(key)
  return vim.base64.encode(sha1(key .. GUID))
end

--- @class bodgery.ws.Conn
--- @field private http bodgery.http.Conn
--- @field private buf string
--- @field closed boolean
local Conn = {}
Conn.__index = Conn

--- @param text string
function Conn:send(text)
  if not self.closed then
    self.http.tcp:write(M.encode(M.OP.TEXT, text))
  end
end

--- Sends a close frame and closes the socket.
--- @param code? integer default 1000
--- @param reason? string
function Conn:close(code, reason)
  if self.closed then
    return
  end
  self.closed = true
  local tcp = self.http.tcp
  if not tcp:is_closing() then
    tcp:read_stop()
    tcp:write(M.encode(M.OP.CLOSE, uint(code or 1000, 2) .. (reason or '')))
    tcp:shutdown(function()
      http.close(self.http)
    end)
  end
end

--- @param opts bodgery.ws.Opts
function Conn:read(opts)
  while not self.closed do
    local frame, consumed, code = M.decode(self.buf)
    if code then
      return self:close(code, 'protocol error')
    elseif not frame then
      return
    end
    self.buf = self.buf:sub(consumed + 1)

    if not frame.masked then
      return self:close(1002, 'unmasked client frame')
    elseif frame.opcode == M.OP.CONTINUATION or frame.opcode == M.OP.BINARY or not frame.fin then
      return self:close(1003, 'fragmented and binary messages are not supported')
    elseif frame.opcode == M.OP.PING then
      self.http.tcp:write(M.encode(M.OP.PONG, frame.payload))
    elseif frame.opcode == M.OP.CLOSE then
      local echo = #frame.payload >= 2 and (frame.payload:byte(1) * 256 + frame.payload:byte(2)) or 1000
      return self:close(echo)
    elseif frame.opcode == M.OP.TEXT then
      vim.schedule(function()
        if not self.closed then
          opts.on_message(self, frame.payload)
        end
      end)
    end
  end
end

--- @class bodgery.ws.Opts
--- @field path string
--- @field token fun(): string the expected `X-Claude-Code-Ide-Authorization` value
--- @field on_open? fun(conn: bodgery.ws.Conn)
--- @field on_message fun(conn: bodgery.ws.Conn, text: string)
--- @field on_close? fun(conn: bodgery.ws.Conn)

--- An HTTP route that upgrades matching requests to websocket connections.
--- @param opts bodgery.ws.Opts
--- @return bodgery.http.Route
function M.route(opts)
  return {
    method = 'GET',
    path = opts.path,
    public = true,
    handler = function(req)
      local h = req.headers
      local key = h['sec-websocket-key']
      if
        not (h['upgrade'] or ''):lower():find('websocket', 1, true)
        or not (h['connection'] or ''):lower():find('upgrade', 1, true)
        or h['sec-websocket-version'] ~= '13'
        or not key
      then
        return 400, { error = 'expected a websocket upgrade' }
      end
      if h['x-claude-code-ide-authorization'] ~= opts.token() then
        return 401, { error = 'unauthorized' }
      end

      local lines = {
        'HTTP/1.1 101 Switching Protocols',
        'Upgrade: websocket',
        'Connection: Upgrade',
        'Sec-WebSocket-Accept: ' .. M.accept_key(key),
      }
      local protocols = h['sec-websocket-protocol'] or ''
      if vim.list_contains(vim.split(protocols, '%s*,%s*'), 'mcp') then
        lines[#lines + 1] = 'Sec-WebSocket-Protocol: mcp'
      end
      req.conn.tcp:write(table.concat(lines, '\r\n') .. '\r\n\r\n')

      local conn = setmetatable({ http = req.conn, buf = http.detach(req.conn), closed = false }, Conn)
      req.conn.on_close = function()
        conn.closed = true
        if opts.on_close then
          vim.schedule(function()
            opts.on_close(conn)
          end)
        end
      end
      if opts.on_open then
        opts.on_open(conn)
      end
      conn:read(opts)
      req.conn.tcp:read_start(function(err, data)
        if err or not data then
          return http.close(req.conn)
        end
        conn.buf = conn.buf .. data
        conn:read(opts)
      end)
    end,
  }
end

return M
