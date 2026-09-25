local rpc = require('bodging.server.rpc')

local M = {}

M.VERSION = '0.1.0'

-- newest first; an unknown client version gets the newest
M.PROTOCOL_VERSIONS = { '2025-06-18', '2025-03-26', '2024-11-05' }

--- @class bodging.mcp.Tool
--- @field name string
--- @field description string
--- @field input_schema? table JSON schema for the arguments
--- @field handler fun(args: table, ctx: table): any a result, or a function receiving `resolve`

--- Turns a handler's return value into an MCP tool result: strings become text, tables
--- with `content` pass through, and other values become JSON text.
--- @param value any
--- @return table
function M.result(value)
  if type(value) == 'string' then
    return { content = { { type = 'text', text = value } } }
  elseif type(value) == 'table' and value.content then
    return value
  elseif value == nil then
    return { content = {} }
  end
  return { content = { { type = 'text', text = vim.json.encode(value) } } }
end

--- @param err any
--- @return table
local function error_result(err)
  return { content = { { type = 'text', text = tostring(err) } }, isError = true }
end

--- @class bodging.mcp.Opts
--- @field name string server name shown to Claude
--- @field tools fun(ctx: table): bodging.mcp.Tool[]

--- @param opts bodging.mcp.Opts
--- @return bodging.rpc.Dispatcher
function M.new(opts)
  local d = rpc.new()

  d:on('initialize', function(params)
    local requested = type(params) == 'table' and params.protocolVersion
    return {
      protocolVersion = vim.list_contains(M.PROTOCOL_VERSIONS, requested) and requested
        or M.PROTOCOL_VERSIONS[1],
      capabilities = { tools = vim.empty_dict() },
      serverInfo = { name = opts.name, version = M.VERSION },
    }
  end)
  d:on('notifications/initialized', function() end)
  d:on('ping', function()
    return vim.empty_dict()
  end)

  d:on('tools/list', function(_, ctx)
    local list = {}
    for _, tool in ipairs(opts.tools(ctx)) do
      list[#list + 1] = {
        name = tool.name,
        description = tool.description,
        inputSchema = tool.input_schema or { type = 'object', properties = vim.empty_dict() },
      }
    end
    return { tools = list }
  end)

  d:on('tools/call', function(params, ctx)
    local name = type(params) == 'table' and params.name
    local tool
    for _, t in ipairs(opts.tools(ctx)) do
      if t.name == name then
        tool = t
        break
      end
    end
    if not tool then
      rpc.error(rpc.INVALID_PARAMS, 'unknown tool: ' .. tostring(name))
    end

    local ok, value = pcall(tool.handler, params.arguments or {}, ctx)
    if not ok then
      return error_result(value)
    elseif type(value) ~= 'function' then
      return M.result(value)
    end
    return function(resolve)
      return value(function(v)
        resolve(M.result(v))
      end)
    end
  end)

  return d
end

--- Serves `dispatcher` on `POST <path>` with JSON replies. `initialize` issues an
--- `Mcp-Session-Id` that later requests must carry.
--- @param dispatcher bodging.rpc.Dispatcher
--- @param path string
--- @return bodging.http.Route
function M.http_route(dispatcher, path)
  local sessions = {}
  return {
    method = 'POST',
    path = path,
    handler = function(req, respond)
      local ok, msg = pcall(vim.json.decode, req.body)
      local initialize = ok and type(msg) == 'table' and msg.method == 'initialize'
      if not initialize then
        local sid = req.headers['mcp-session-id']
        if not sid then
          return 400, { error = 'missing Mcp-Session-Id' }
        elseif not sessions[sid] then
          return 404, { error = 'unknown Mcp-Session-Id' }
        end
      end

      local conn = rpc.conn()
      req.conn.on_close = function()
        rpc.close(conn)
      end
      dispatcher:handle(req.body, req.ctx, conn, function(res)
        req.conn.on_close = nil
        if not res then
          return respond(202)
        end
        local headers
        if initialize and res.result then
          local sid = vim.text.hexencode(assert(vim.uv.random(16)))
          sessions[sid] = true
          headers = { ['Mcp-Session-Id'] = sid }
        end
        respond(200, res, headers)
      end)
    end,
  }
end

--- Websocket callbacks serving `dispatcher`, one RPC connection per socket.
--- @param dispatcher bodging.rpc.Dispatcher
--- @return { on_open: fun(conn: bodging.ws.Conn), on_message: fun(conn: bodging.ws.Conn, text: string), on_close: fun(conn: bodging.ws.Conn) }
function M.ws_handlers(dispatcher)
  local conns = setmetatable({}, { __mode = 'k' })
  return {
    on_open = function(ws)
      conns[ws] = rpc.conn()
    end,
    on_message = function(ws, text)
      dispatcher:handle(text, { ws = ws }, conns[ws], function(res)
        if res then
          ws:send(vim.json.encode(res))
        end
      end)
    end,
    on_close = function(ws)
      rpc.close(conns[ws])
    end,
  }
end

return M
