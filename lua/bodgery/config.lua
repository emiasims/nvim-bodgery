local M = {}

--- @class bodgery.ToolSpec
--- @field description string
--- @field input_schema? table
--- @field handler fun(args: table, ctx: { session_id: string?, bufnr: integer }): any

--- Core options, plus the options of the harness module `harness.<name>.config`.
--- @class bodgery.Config: bodgery.claude.Config
--- @field name string key in |bodgery.configs|, defaults to `harness`
--- @field harness string key in |bodgery.harnesses|
--- @field cmd string[] command and default flags
--- @field command string user command that opens this config, defaults to the capitalized
---   harness name. Configs sharing a command are picked by name as its first argument.
--- @field tools table<string, bodgery.ToolSpec>
--- @field on_busy 'error'|'interrupt'|'queue'|'prompt'
--- @field active bodgery.Resolver[] picks the terminal a call without a `bufnr` acts on
--- @field root_markers string[] passed to |vim.fs.root()| by the `project` resolver
--- @field show { window: fun(ctx: bodgery.Context, term?: bodgery.Terminal): integer }
---   picks the window that shows a hidden or new terminal
--- @field restore { max_age: number } seconds
--- @field editor { open: fun(file: string) }
M.defaults = {
  harness = 'claude',
  tools = {},
  on_busy = 'error',
  active = { 'window', 'tab', 'global', 'new' },
  root_markers = { '.git' },
  show = {
    window = function(ctx)
      local vertical = vim.api.nvim_win_get_width(ctx.win) >= 2 * vim.api.nvim_win_get_height(ctx.win)
      return vim.api.nvim_open_win(0, false, { vertical = vertical, win = ctx.win })
    end,
  },
  restore = { max_age = 30 * 24 * 60 * 60 },
  editor = {
    open = function(file)
      vim.cmd.split({ file, magic = { file = false } })
    end,
  },
}

local on_busy = { 'error', 'interrupt', 'queue', 'prompt' }

--- Resolvers named in `active`, from `bodgery.terminal`.
M.resolvers = { 'window', 'buffer', 'tab', 'global', 'project', 'new', 'pick', 'error' }

-- replaced whole by a layer that sets them, where tables merge by key
local lists = { 'active', 'cmd', 'root_markers' }

-- sorted so a parent table is checked before its fields
local schema = {
  { 'active', 'table' },
  { 'cmd', 'table' },
  { 'command', 'string' },
  { 'editor', 'table' },
  { 'editor.open', 'function' },
  { 'harness', 'string' },
  { 'name', 'string' },
  { 'on_busy', 'string' },
  { 'restore', 'table' },
  { 'restore.max_age', 'number' },
  { 'root_markers', 'table' },
  { 'show', 'table' },
  { 'show.window', 'function' },
  { 'tools', 'table' },
}

local function fail(fmt, ...)
  error('bodgery: ' .. fmt:format(...), 0)
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

  for i, entry in ipairs(opts.active) do
    local name = ('active[%d]'):format(i)
    if type(entry) == 'string' then
      if not vim.list_contains(M.resolvers, entry) then
        fail('%s: expected one of %s, got %q', name, table.concat(M.resolvers, ', '), entry)
      end
    else
      expect(name, entry, 'function')
    end
  end
  for i, marker in ipairs(opts.root_markers) do
    expect(('root_markers[%d]'):format(i), marker, 'string')
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
--- @return bodgery.Config
function M.resolve(opts)
  opts = opts or {}
  expect('opts', opts, 'table')
  local name = opts.harness or M.defaults.harness
  expect('harness', name, 'string')
  if not require('bodgery').harnesses._submodules[name] then
    fail('harness: unknown harness %q', name)
  end
  local harness = require(('bodgery.harness.%s.config'):format(name))

  local merged = vim.tbl_deep_extend('force', {}, M.defaults, harness.defaults, opts)
  for _, key in ipairs(lists) do
    merged[key] = opts[key] or harness.defaults[key] or M.defaults[key]
  end
  merged.name = opts.name or merged.harness
  validate(merged, harness)
  return merged
end

--- @alias bodgery.ConfigArg string|table a config name, or a table with the name of the
---   config it overrides in `name`

--- The config `config` names, or `config` merged over the config its `name` names.
--- @param config bodgery.ConfigArg
--- @return bodgery.Config
function M.get(config)
  local configs = require('bodgery').configs
  if type(config) == 'string' then
    return configs[config]
  end
  expect('config', config, 'table')
  expect('config.name', config.name, 'string')
  local base = configs[config.name]
  local merged = vim.tbl_deep_extend('force', {}, base, config)
  for _, key in ipairs(lists) do
    merged[key] = config[key] or base[key]
  end
  validate(merged, require(('bodgery.harness.%s.config'):format(merged.harness)))
  return merged
end

return M
