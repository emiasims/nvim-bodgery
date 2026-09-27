local uv = vim.uv

local M = {}

local reasons = {
  [200] = 'OK',
  [202] = 'Accepted',
  [400] = 'Bad Request',
  [401] = 'Unauthorized',
  [404] = 'Not Found',
  [405] = 'Method Not Allowed',
  [413] = 'Content Too Large',
  [431] = 'Request Header Fields Too Large',
  [500] = 'Internal Server Error',
}

local MAX_HEADER = 64 * 1024

--- @class bodgery.http.Request
--- @field method string
--- @field path string
--- @field headers table<string, string> lowercase names
--- @field body string
--- @field token? string bearer token from `Authorization`
--- @field ctx any what the auth lookup returned for the token
--- @field conn bodgery.http.Conn

--- @alias bodgery.http.Respond fun(status: integer, body?: table|string, headers?: table<string, string>)

--- @class bodgery.http.Route
--- @field method string
--- @field path string
--- @field handler fun(req: bodgery.http.Request, respond: bodgery.http.Respond): integer?, (table|string)?, table<string, string>?
--- @field public? boolean skip the bearer token check

--- Parses one request from the front of `buf`.
--- @return bodgery.http.Request|integer|nil req a request, an error status, or nil when incomplete
--- @return string rest
local function parse(buf, max_body)
  local head_end = buf:find('\r\n\r\n', 1, true)
  if not head_end then
    return #buf > MAX_HEADER and 431 or nil, buf
  end
  if head_end > MAX_HEADER then
    return 431, buf
  end

  local lines = vim.split(buf:sub(1, head_end - 1), '\r\n', { plain = true })
  local method, target, version = lines[1]:match('^(%u+) (%S+) HTTP/(%d%.%d)$')
  if not method then
    return 400, buf
  end
  local headers = {}
  for i = 2, #lines do
    local name, value = lines[i]:match('^([^:%s]+):%s*(.-)%s*$')
    if not name then
      return 400, buf
    end
    name = name:lower()
    headers[name] = headers[name] and (headers[name] .. ', ' .. value) or value
  end

  local rest = buf:sub(head_end + 4)
  local body
  if (headers['transfer-encoding'] or ''):lower():find('chunked', 1, true) then
    local parts, pos, size = {}, 1, 0
    while true do
      local line_end = rest:find('\r\n', pos, true)
      if not line_end then
        return nil, buf
      end
      local n = tonumber(rest:sub(pos, line_end - 1):match('^%x+'), 16)
      if not n then
        return 400, buf
      end
      size = size + n
      if size > max_body then
        return 413, buf
      end
      if n == 0 then
        -- skip trailers up to the blank line
        local trailer_end = rest:find('\r\n\r\n', line_end, true)
        if rest:sub(line_end, line_end + 3) == '\r\n\r\n' then
          trailer_end = line_end
        end
        if not trailer_end then
          return nil, buf
        end
        rest = rest:sub(trailer_end + 4)
        break
      end
      local data_end = line_end + 2 + n
      if #rest < data_end + 1 then
        return nil, buf
      end
      parts[#parts + 1] = rest:sub(line_end + 2, data_end - 1)
      pos = data_end + 2
    end
    body = table.concat(parts)
  else
    local len = tonumber(headers['content-length'] or '0')
    if not len or len < 0 then
      return 400, buf
    end
    if len > max_body then
      return 413, buf
    end
    if #rest < len then
      return nil, buf
    end
    body, rest = rest:sub(1, len), rest:sub(len + 1)
  end

  local connection = (headers['connection'] or ''):lower()
  --- @type bodgery.http.Request
  local req = {
    method = method,
    path = target:match('^[^?]*'),
    headers = headers,
    body = body,
    token = (headers['authorization'] or ''):match('^Bearer%s+(%S+)$'),
    keep_alive = version == '1.1' and connection ~= 'close' or connection == 'keep-alive',
  }
  return req, rest
end

--- @param status integer
--- @param body? table|string
--- @param headers? table<string, string>
--- @param close boolean
local function format(status, body, headers, close)
  if type(body) == 'table' then
    body = vim.json.encode(body)
  end
  body = body or ''
  local lines = { ('HTTP/1.1 %d %s'):format(status, reasons[status] or '') }
  local all = vim.tbl_extend('force', {
    ['Content-Type'] = 'application/json',
    ['Content-Length'] = tostring(#body),
  }, headers or {})
  if close then
    all['Connection'] = 'close'
  end
  for name, value in pairs(all) do
    lines[#lines + 1] = name .. ': ' .. value
  end
  return table.concat(lines, '\r\n') .. '\r\n\r\n' .. body
end

--- @class bodgery.http.Conn
--- @field tcp uv.uv_tcp_t
--- @field buf string
--- @field busy boolean a request is being handled, later ones wait
--- @field closed boolean
--- @field detached boolean another protocol owns the socket
--- @field on_close? fun()

--- @class bodgery.http.Server
--- @field port integer
--- @field private tcp uv.uv_tcp_t
--- @field private conns table<bodgery.http.Conn, true>
--- @field private routes bodgery.http.Route[]
--- @field private auth fun(token: string): any
--- @field private max_body integer
local Server = {}
Server.__index = Server

--- @param conn bodgery.http.Conn
function Server:close_conn(conn)
  if conn.closed then
    return
  end
  conn.closed = true
  self.conns[conn] = nil
  if not conn.tcp:is_closing() then
    conn.tcp:close()
  end
  if conn.on_close then
    conn.on_close()
  end
end

--- @param conn bodgery.http.Conn
--- @param req bodgery.http.Request
function Server:dispatch(conn, req)
  local responded = false
  --- @type bodgery.http.Respond
  local function respond(status, body, headers)
    if responded or conn.closed then
      return
    end
    responded = true
    local close = not req.keep_alive or status == 413
    conn.tcp:write(format(status, body, headers, close))
    conn.busy = false
    if close then
      conn.tcp:shutdown(function()
        self:close_conn(conn)
      end)
    else
      self:process(conn)
    end
  end

  local route, path_known = nil, false
  for _, r in ipairs(self.routes) do
    if r.path == req.path then
      path_known = true
      if r.method == req.method then
        route = r
        break
      end
    end
  end
  if not route then
    return respond(
      path_known and 405 or 404,
      { error = path_known and 'method not allowed' or 'not found' }
    )
  end

  if not route.public then
    req.ctx = req.token and self.auth(req.token)
    if not req.ctx then
      return respond(401, { error = 'unauthorized' })
    end
  end

  req.conn = conn
  vim.schedule(function()
    if conn.closed then
      return
    end
    local ok, status, body, headers = pcall(route.handler, req, respond)
    if not ok then
      respond(500, { error = tostring(status) })
    elseif status then
      respond(status, body, headers)
    end
  end)
end

--- Handles buffered requests one at a time, so responses go out in request order.
--- @param conn bodgery.http.Conn
function Server:process(conn)
  if conn.busy or conn.closed or conn.detached then
    return
  end
  local req, rest = parse(conn.buf, self.max_body)
  if not req then
    return
  end
  if type(req) == 'number' then
    conn.busy = true
    conn.tcp:write(format(req, { error = reasons[req] }, nil, true))
    conn.tcp:shutdown(function()
      self:close_conn(conn)
    end)
    return
  end
  conn.buf = rest
  conn.busy = true
  self:dispatch(conn, req)
end

--- Hands the socket to another protocol. The server stops reading from it but still
--- closes it on `stop()`.
--- @param conn bodgery.http.Conn
--- @return string rest bytes received after the request
function M.detach(conn)
  conn.detached = true
  conn.tcp:read_stop()
  local rest = conn.buf
  conn.buf = ''
  return rest
end

--- @param conn bodgery.http.Conn
function M.close(conn)
  conn.server:close_conn(conn)
end

--- @param client uv.uv_tcp_t
function Server:accept(client)
  --- @type bodgery.http.Conn
  local conn = { tcp = client, buf = '', busy = false, closed = false, detached = false, server = self }
  self.conns[conn] = true
  client:read_start(function(err, data)
    if err or not data then
      return self:close_conn(conn)
    end
    conn.buf = conn.buf .. data
    self:process(conn)
  end)
end

--- Adds a route. Routes added later win over earlier ones for the same method and path.
--- @param route bodgery.http.Route
function Server:route(route)
  table.insert(self.routes, 1, route)
end

function Server:stop()
  if not self.tcp:is_closing() then
    self.tcp:close()
  end
  for conn in pairs(self.conns) do
    self:close_conn(conn)
  end
end

--- @class bodgery.http.Opts
--- @field routes? bodgery.http.Route[]
--- @field auth fun(token: string): any returns a context for a known token, nil otherwise
--- @field max_body? integer bytes, default 16 MiB

--- Listens on 127.0.0.1 on a port the OS picks.
--- @param opts bodgery.http.Opts
--- @return bodgery.http.Server
function M.start(opts)
  local tcp = assert(uv.new_tcp())
  local self = setmetatable({
    tcp = tcp,
    conns = {},
    routes = vim.list_extend({}, opts.routes or {}),
    auth = opts.auth,
    max_body = opts.max_body or 16 * 1024 * 1024,
  }, Server)

  assert(tcp:bind('127.0.0.1', 0))
  assert(tcp:listen(128, function(err)
    if err then
      return
    end
    local client = assert(uv.new_tcp())
    if tcp:accept(client) then
      self:accept(client)
    else
      client:close()
    end
  end))
  self.port = tcp:getsockname().port
  return self
end

return M
