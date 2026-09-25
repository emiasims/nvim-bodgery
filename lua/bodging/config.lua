local M = {}

--- @class bodging.ToolSpec
--- @field description string
--- @field input_schema? table
--- @field handler fun(args: table, ctx: { session_id: string?, bufnr: integer }): any

--- @class bodging.Config
--- @field name string key in |bodging.configs|, defaults to `harness`
--- @field harness string key in |bodging.harnesses|
--- @field cmd string[] command and default flags
--- @field hooks table<string, fun(input: table): table?> hook event name to callback
--- @field tools table<string, bodging.ToolSpec>
--- @field execute_code boolean serve the `executeCode` IDE tool
--- @field selection { auto: boolean } send `selection_changed` automatically
--- @field on_busy 'error'|'interrupt'|'queue'|'prompt'
--- @field resolve? fun(): integer? picks the target terminal when zero or several are shown
--- @field restore { max_age: number } seconds
--- @field editor { open: fun(file: string) }
--- @field diff { window: fun(): integer, inline: boolean } `window` picks where a proposed edit shows, `inline` marks changes within a line
--- @field ccd_dir string root of ccd's session index
M.defaults = {
  harness = 'claude',
  cmd = { 'claude' },
  hooks = {},
  tools = {},
  execute_code = false,
  selection = { auto = true },
  on_busy = 'error',
  resolve = nil,
  restore = { max_age = 30 * 24 * 60 * 60 },
  editor = {
    open = function(file)
      vim.cmd.split({ file, magic = { file = false } })
    end,
  },
  diff = {
    inline = true,
    window = function()
      return require('bodging.terminal').pick_window()
    end,
  },
  ccd_dir = vim.fs.normalize('~/Library/Application Support/Claude/claude-code-sessions'),
}

M.hook_events = {
  'SessionStart',
  'PreToolUse',
  'PostToolUse',
  'SubagentStart',
  'SubagentStop',
  'UserPromptSubmit',
  'Stop',
  'Notification',
  'SessionEnd',
}

local on_busy = { 'error', 'interrupt', 'queue', 'prompt' }

-- sorted so a parent table is checked before its fields
local schema = {
  { 'ccd_dir', 'string' },
  { 'cmd', 'table' },
  { 'diff', 'table' },
  { 'diff.inline', 'boolean' },
  { 'diff.window', 'function' },
  { 'editor', 'table' },
  { 'editor.open', 'function' },
  { 'execute_code', 'boolean' },
  { 'harness', 'string' },
  { 'hooks', 'table' },
  { 'name', 'string' },
  { 'on_busy', 'string' },
  { 'resolve', 'function', optional = true },
  { 'restore', 'table' },
  { 'restore.max_age', 'number' },
  { 'selection', 'table' },
  { 'selection.auto', 'boolean' },
  { 'tools', 'table' },
}

local function fail(fmt, ...)
  error('bodging: ' .. fmt:format(...), 0)
end

local function expect(name, value, expected, optional)
  if not (type(value) == expected or (optional and value == nil)) then
    fail('%s: expected %s, got %s', name, expected, type(value))
  end
end

--- @param opts table
local function validate(opts)
  local known, nested = {}, {}
  for _, entry in ipairs(schema) do
    local name, expected = entry[1], entry[2]
    known[name] = true
    local path = vim.split(name, '.', { plain = true })
    if #path > 1 then
      nested[path[1]] = true
    end
    expect(name, vim.tbl_get(opts, unpack(path)), expected, entry.optional)
  end

  for key, value in pairs(opts) do
    if not known[key] then
      fail('unknown option %s', key)
    end
    if nested[key] then
      for field in pairs(value) do
        if not known[key .. '.' .. field] then
          fail('unknown option %s.%s', key, field)
        end
      end
    end
  end

  if not require('bodging').harnesses._submodules[opts.harness] then
    fail('harness: unknown harness %q', opts.harness)
  end

  if #opts.cmd == 0 then
    fail('cmd: expected a non-empty list')
  end
  for i, arg in ipairs(opts.cmd) do
    expect(('cmd[%d]'):format(i), arg, 'string')
  end

  if not vim.list_contains(on_busy, opts.on_busy) then
    fail('on_busy: expected one of %s, got %q', table.concat(on_busy, ', '), opts.on_busy)
  end

  for event, callback in pairs(opts.hooks) do
    if not vim.list_contains(M.hook_events, event) then
      fail('hooks.%s: unknown hook event', event)
    end
    expect('hooks.' .. event, callback, 'function')
  end

  for name, spec in pairs(opts.tools) do
    local prefix = 'tools.' .. name
    expect(prefix, spec, 'table')
    expect(prefix .. '.description', spec.description, 'string')
    expect(prefix .. '.input_schema', spec.input_schema, 'table', true)
    expect(prefix .. '.handler', spec.handler, 'function')
  end
end

--- Validates `opts` and merges it over the defaults.
--- @param opts? table
--- @return bodging.Config
function M.resolve(opts)
  opts = opts or {}
  expect('opts', opts, 'table')
  local merged = vim.tbl_deep_extend('force', {}, M.defaults, opts)
  -- lists replace the default instead of merging by index
  merged.cmd = opts.cmd or M.defaults.cmd
  merged.name = opts.name or merged.harness
  validate(merged)
  return merged
end

return M
