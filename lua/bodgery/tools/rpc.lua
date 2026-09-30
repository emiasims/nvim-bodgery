local M = {}

--- API verbs that only read, from `:h dev-name-common`. `list` is deprecated there but
--- still names functions like `nvim_list_bufs`.
local read_verbs = { get = true, list = true, is = true, has = true, parse = true }

--- Whether an API function only reads. Names follow `nvim_{topic}_{verb}_…` or
--- `nvim_{verb}_…` (`:h dev-api-name`), so the verb is the first or second word.
--- @param name string
--- @return boolean
function M.is_read(name)
  local words = vim.split((name:gsub('^nvim_', '')), '_')
  return read_verbs[words[1]] or read_verbs[words[2]] or false
end

--- @param list? any[]
--- @return any ...
local function unpack_all(list)
  list = list or {}
  return unpack(list, 1, table.maxn(list))
end

--- Remote-only API functions, which `vim.api` lacks, that still make sense from inside.
local remote_only = {
  nvim_exec_lua = function(code, args)
    return assert(loadstring(code, '=nvim_exec_lua'))(unpack_all(args))
  end,
}

--- @param value any
--- @return any
local function encodable(value)
  if type(value) == 'function' or type(value) == 'userdata' and value ~= vim.NIL then
    return tostring(value)
  elseif type(value) == 'table' then
    local out = setmetatable({}, getmetatable(value))
    for k, v in pairs(value) do
      out[k] = encodable(v)
    end
    return out
  end
  return value
end

--- Calls API function `method` with `params`, if it is on the side of the read/write split
--- that `read` asks for. Returns the result as JSON.
--- @param read boolean
--- @param method string
--- @param params? any[]
--- @return string
function M.call(read, method, params)
  local fn = vim.api[method] or remote_only[method]
  if not fn then
    error(('no API function %q'):format(method), 0)
  elseif M.is_read(method) ~= read then
    error(
      ('%s is not a %s function, use nvim_rpc_%s'):format(
        method,
        read and 'read-only' or 'writing',
        read and 'write' or 'read'
      ),
      0
    )
  end
  local result = fn(unpack_all(params))
  return vim.json.encode(result == nil and vim.NIL or encodable(result))
end

--- @param read boolean
--- @param description string
--- @return bodgery.ToolSpec
local function spec(read, description)
  return {
    description = description,
    input_schema = {
      type = 'object',
      properties = {
        method = { type = 'string' },
        params = { type = 'array', description = 'arguments in order' },
      },
      required = { 'method' },
    },
    handler = function(args)
      return M.call(read, args.method, args.params)
    end,
  }
end

--- @type table<string, bodgery.ToolSpec>
M.tools = {
  nvim_rpc_read = spec(
    true,
    "Calls a read-only Neovim API function (`:h api`) in the user's session and returns its "
      .. 'result as JSON. Read-only functions are the ones whose verb is get, list, is, has, '
      .. 'or parse, like nvim_buf_get_lines, nvim_list_wins, or nvim_get_option_value. Buffer, '
      .. 'window, and tab handles are integers, and 0 means the current one. Look up a '
      .. "signature with nvim_help, e.g. tag 'nvim_buf_get_lines()'."
  ),
  nvim_rpc_write = spec(
    false,
    "Calls any Neovim API function outside nvim_rpc_read's read-only set, in the user's live "
      .. 'session, and returns its result as JSON. This includes nvim_exec_lua, nvim_exec2, '
      .. 'nvim_buf_set_lines, and nvim_feedkeys. Effects are immediate and can change or '
      .. "discard the user's unsaved edits, windows, and settings. Use nvim_rpc_read or "
      .. 'another nvim_ tool when one can answer.'
  ),
}

return M
