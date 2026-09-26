local M = {}

--- @class bodging.ToolSpec
--- @field description string
--- @field input_schema? table
--- @field handler fun(args: table, ctx: { session_id: string?, bufnr: integer }): any

--- Core options, plus the options of the harness module `harness.<name>.config`.
--- @class bodging.Config: bodging.claude.Config
--- @field name string key in |bodging.configs|, defaults to `harness`
--- @field harness string key in |bodging.harnesses|
--- @field cmd string[] command and default flags
--- @field command string user command that opens this config, defaults to the capitalized
---   harness name. Configs sharing a command are picked by name as its first argument.
--- @field tools table<string, bodging.ToolSpec>
--- @field on_busy 'error'|'interrupt'|'queue'|'prompt'
--- @field resolve? fun(): integer? picks the target terminal when zero or several are shown
--- @field restore { max_age: number } seconds
--- @field editor { open: fun(file: string) }
M.defaults = {
  harness = 'claude',
  tools = {},
  on_busy = 'error',
  resolve = nil,
  restore = { max_age = 30 * 24 * 60 * 60 },
  editor = {
    open = function(file)
      vim.cmd.split({ file, magic = { file = false } })
    end,
  },
}

local on_busy = { 'error', 'interrupt', 'queue', 'prompt' }

-- sorted so a parent table is checked before its fields
local schema = {
  { 'cmd', 'table' },
  { 'command', 'string' },
  { 'editor', 'table' },
  { 'editor.open', 'function' },
  { 'harness', 'string' },
  { 'name', 'string' },
  { 'on_busy', 'string' },
  { 'resolve', 'function', optional = true },
  { 'restore', 'table' },
  { 'restore.max_age', 'number' },
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
--- @param harness table the harness's config module
local function validate(opts, harness)
  local known, nested = {}, {}
  for _, entries in ipairs({ schema, harness.schema }) do
    for _, entry in ipairs(entries) do
      local name, expected = entry[1], entry[2]
      known[name] = true
      local path = vim.split(name, '.', { plain = true })
      if #path > 1 then
        nested[path[1]] = true
      end
      expect(name, vim.tbl_get(opts, unpack(path)), expected, entry.optional)
    end
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

  if #opts.cmd == 0 then
    fail('cmd: expected a non-empty list')
  end
  for i, arg in ipairs(opts.cmd) do
    expect(('cmd[%d]'):format(i), arg, 'string')
  end

  if not vim.list_contains(on_busy, opts.on_busy) then
    fail('on_busy: expected one of %s, got %q', table.concat(on_busy, ', '), opts.on_busy)
  end

  for name, spec in pairs(opts.tools) do
    local prefix = 'tools.' .. name
    expect(prefix, spec, 'table')
    expect(prefix .. '.description', spec.description, 'string')
    expect(prefix .. '.input_schema', spec.input_schema, 'table', true)
    expect(prefix .. '.handler', spec.handler, 'function')
  end

  harness.validate(opts, fail, expect)
end

--- Validates `opts` and merges it over the core and harness defaults.
--- @param opts? table
--- @return bodging.Config
function M.resolve(opts)
  opts = opts or {}
  expect('opts', opts, 'table')
  local name = opts.harness or M.defaults.harness
  expect('harness', name, 'string')
  if not require('bodging').harnesses._submodules[name] then
    fail('harness: unknown harness %q', name)
  end
  local harness = require(('bodging.harness.%s.config'):format(name))

  local merged = vim.tbl_deep_extend('force', {}, M.defaults, harness.defaults, opts)
  -- lists replace the default instead of merging by index
  merged.cmd = opts.cmd or harness.defaults.cmd
  merged.name = opts.name or merged.harness
  validate(merged, harness)
  return merged
end

return M
