local M = {}

M.PARSE_ERROR = -32700
M.INVALID_REQUEST = -32600
M.METHOD_NOT_FOUND = -32601
M.INVALID_PARAMS = -32602
M.INTERNAL_ERROR = -32603

--- A connection that can hold deferred replies. Closing it drops them.
--- @class claude-code.rpc.Conn
--- @field closed boolean
--- @field pending table<table, fun()?> deferred replies to their cancel callbacks

--- @return claude-code.rpc.Conn
function M.conn()
  return { closed = false, pending = {} }
end

--- Marks `conn` closed and cancels its deferred replies.
--- @param conn claude-code.rpc.Conn
function M.close(conn)
  conn.closed = true
  local pending = conn.pending
  conn.pending = {}
  for _, cancel in pairs(pending) do
    if cancel then
      pcall(cancel)
    end
  end
end

--- Raises a JSON-RPC error with `code` from a handler.
--- @param code integer
--- @param message string
function M.error(code, message)
  error({ code = code, message = message }, 0)
end

--- A handler's return: a result, or a function that receives `resolve` (and may return a
--- cancel callback run when the connection closes first).
--- @alias claude-code.rpc.Handler fun(params: any, ctx: table): any

--- @class claude-code.rpc.Dispatcher
--- @field methods table<string, claude-code.rpc.Handler>
local Dispatcher = {}
Dispatcher.__index = Dispatcher

--- @return claude-code.rpc.Dispatcher
function M.new()
  return setmetatable({ methods = {} }, Dispatcher)
end

--- @param name string
--- @param handler claude-code.rpc.Handler
function Dispatcher:on(name, handler)
  self.methods[name] = handler
end

local function error_response(id, code, message)
  return { jsonrpc = '2.0', id = id == nil and vim.NIL or id, error = { code = code, message = message } }
end

--- Handles one message. `reply` is called once with the response, or with nil for
--- notifications and messages that need none. Deferred replies are sent only while `conn`
--- is open.
--- @param raw string
--- @param ctx table passed to handlers
--- @param conn claude-code.rpc.Conn
--- @param reply fun(response: table?)
function Dispatcher:handle(raw, ctx, conn, reply)
  local ok, msg = pcall(vim.json.decode, raw, { luanil = { object = true, array = true } })
  if not ok then
    return reply(error_response(nil, M.PARSE_ERROR, 'parse error'))
  end
  if type(msg) ~= 'table' or msg.jsonrpc ~= '2.0' then
    return reply(
      error_response(type(msg) == 'table' and msg.id or nil, M.INVALID_REQUEST, 'invalid request')
    )
  end
  if msg.method == nil and (msg.result ~= nil or msg.error ~= nil) then
    -- a response to a request this server never sends
    return reply(nil)
  end
  if type(msg.method) ~= 'string' then
    return reply(error_response(msg.id, M.INVALID_REQUEST, 'invalid request'))
  end

  local id, notification = msg.id, msg.id == nil
  local function send(response)
    reply(not notification and response or nil)
  end

  local handler = self.methods[msg.method]
  if not handler then
    if notification then
      return reply(nil)
    end
    return send(error_response(id, M.METHOD_NOT_FOUND, 'method not found: ' .. msg.method))
  end

  local function failure(err)
    if type(err) == 'table' and err.code then
      return error_response(id, err.code, err.message)
    end
    return error_response(id, M.INTERNAL_ERROR, tostring(err))
  end

  local hok, result = pcall(handler, msg.params, ctx)
  if not hok then
    return send(failure(result))
  end
  if type(result) ~= 'function' then
    return send({ jsonrpc = '2.0', id = id, result = result == nil and vim.empty_dict() or result })
  end

  local key, done = {}, false
  local function resolve(value)
    if done or conn.closed then
      return
    end
    done = true
    conn.pending[key] = nil
    send({ jsonrpc = '2.0', id = id, result = value == nil and vim.empty_dict() or value })
  end
  conn.pending[key] = false
  local dok, cancel = pcall(result, resolve)
  if not dok then
    done = true
    conn.pending[key] = nil
    return send(failure(cancel))
  end
  if not done then
    conn.pending[key] = cancel or false
  end
end

return M
