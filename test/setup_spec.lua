local helpers = require('nvim-test.helpers')
local exec_lua = helpers.exec_lua
local eq = helpers.eq

-- functions can't cross RPC, so the child turns this sentinel into one
local fn = '<function>'

--- @param opts table
--- @return string?
local function setup_error(opts)
  return exec_lua(function(o, sentinel)
    local function revive(t)
      for k, v in pairs(t) do
        if v == sentinel then
          t[k] = function() end
        elseif type(v) == 'table' then
          revive(v)
        end
      end
      return t
    end
    local ok, err = pcall(require('claude-code').setup, revive(o))
    return not ok and err or nil
  end, opts, fn)
end

describe('setup', function()
  before_each(function()
    helpers.clear()
    exec_lua('package.path = ...', package.path)
  end)

  it('leaves one autocmd per event after a second call', function()
    local counts = exec_lua(function()
      local cc = require('claude-code')
      cc.setup()
      cc.setup({ cmd = { 'claude', '--verbose' } })
      local counts = {}
      for _, au in ipairs(vim.api.nvim_get_autocmds({ group = 'claude-code' })) do
        counts[au.event] = (counts[au.event] or 0) + 1
      end
      return counts
    end)
    for event, n in pairs(counts) do
      eq(1, n, event)
    end
  end)

  it('replaces the configuration on a second call', function()
    local config = exec_lua(function()
      local cc = require('claude-code')
      cc.setup({ cmd = { 'claude', '--verbose' }, on_busy = 'queue' })
      cc.setup({ cmd = { 'other' } })
      return { cmd = cc.config.cmd, on_busy = cc.config.on_busy }
    end)
    eq({ cmd = { 'other' }, on_busy = 'error' }, config)
  end)

  it('keeps the running configuration when validation fails', function()
    local cmd = exec_lua(function()
      local cc = require('claude-code')
      cc.setup({ cmd = { 'first' } })
      pcall(cc.setup, { cmd = 'second' })
      return cc.config.cmd
    end)
    eq({ 'first' }, cmd)
  end)

  local bad = {
    { 'cmd', { cmd = 'claude' } },
    { 'cmd', { cmd = {} } },
    { 'cmd[2]', { cmd = { 'claude', 1 } } },
    { 'hooks', { hooks = fn } },
    { 'hooks.Stop', { hooks = { Stop = true } } },
    { 'hooks.Bogus', { hooks = { Bogus = fn } } },
    { 'tools', { tools = 'x' } },
    { 'tools.t', { tools = { t = fn } } },
    { 'tools.t.description', { tools = { t = { handler = fn } } } },
    { 'tools.t.handler', { tools = { t = { description = 'd' } } } },
    { 'tools.t.input_schema', { tools = { t = { description = 'd', handler = fn, input_schema = 'x' } } } },
    { 'execute_code', { execute_code = 1 } },
    { 'selection', { selection = true } },
    { 'selection.auto', { selection = { auto = 'yes' } } },
    { 'on_busy', { on_busy = 1 } },
    { 'on_busy', { on_busy = 'wait' } },
    { 'resolve', { resolve = 1 } },
    { 'restore', { restore = 1 } },
    { 'restore.max_age', { restore = { max_age = '1d' } } },
    { 'editor', { editor = fn } },
    { 'editor.open', { editor = { open = 'split' } } },
    { 'ccd_dir', { ccd_dir = 1 } },
    { 'nope', { nope = 1 } },
    { 'restore.nope', { restore = { nope = 1 } } },
  }

  for _, case in ipairs(bad) do
    local key, opts = case[1], case[2]
    it(
      ('names %s in the error for %s'):format(key, vim.inspect(opts, { newline = ' ', indent = '' })),
      function()
        local err = setup_error(opts)
        assert(err, 'expected an error')
        assert(err:find(key, 1, true), err)
      end
    )
  end

  it('accepts a full valid configuration', function()
    local err = setup_error({
      cmd = { 'claude', '--model', 'opus' },
      hooks = { Stop = fn },
      tools = { t = { description = 'd', input_schema = {}, handler = fn } },
      execute_code = true,
      selection = { auto = false },
      on_busy = 'prompt',
      resolve = fn,
      restore = { max_age = 60 },
      editor = { open = fn },
      ccd_dir = '/tmp',
    })
    assert(err == nil, err)
  end)
end)
