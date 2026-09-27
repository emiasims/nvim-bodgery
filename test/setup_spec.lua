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
    local cc = require('bodging')
    local ok, err = pcall(function()
      cc.setup(revive(o))
      return cc.configs[o.name or o.harness or 'claude']
    end)
    return not ok and err or nil
  end, opts, fn)
end

describe('setup', function()
  before_each(require('test.helpers').clear)

  it('loads no other module', function()
    local loaded = exec_lua(function()
      local before = vim.tbl_keys(package.loaded)
      require('bodging').setup()
      return vim.tbl_filter(function(name)
        return name:match('^bodging%.') ~= nil and not vim.list_contains(before, name)
      end, vim.tbl_keys(package.loaded))
    end)
    eq({}, loaded)
  end)

  describe('detect', function()
    --- Puts an executable `claude` alone on the path.
    local function fake_claude()
      exec_lua(function()
        local dir = vim.fn.tempname()
        vim.fn.mkdir(dir, 'p')
        vim.fn.writefile({ '#!/bin/sh' }, dir .. '/claude')
        vim.uv.fs_chmod(dir .. '/claude', 493)
        vim.env.PATH = dir
      end)
    end

    it('creates a config and command for an installed harness', function()
      fake_claude()
      local result = exec_lua(function()
        local cc = require('bodging')
        cc.detect()
        return { cmd = cc.configs.claude.cmd, exists = vim.fn.exists(':Claude') }
      end)
      eq({ cmd = { 'claude' }, exists = 2 }, result)
    end)

    it('skips a harness without its config directory', function()
      fake_claude()
      local exists = exec_lua(function()
        vim.fn.delete(vim.env.CLAUDE_CONFIG_DIR, 'rf')
        require('bodging').detect()
        return vim.fn.exists(':Claude')
      end)
      eq(0, exists)
    end)

    it('gives way to a setup() config for the same harness', function()
      fake_claude()
      local result = exec_lua(function()
        local cc = require('bodging')
        cc.detect()
        cc.setup({ name = 'work' })
        cc.detect()
        return {
          ok = pcall(function()
            return cc.configs.claude
          end),
          completion = vim.fn.getcompletion('Claude ', 'cmdline'),
        }
      end)
      eq({ ok = false, completion = { 'work' } }, result)
    end)
  end)

  it('leaves one autocmd per event after a second call', function()
    local counts = exec_lua(function()
      local cc = require('bodging')
      cc.setup()
      cc.start('claude')
      cc.setup({ cmd = { 'claude', '--verbose' } })
      cc.start('claude')
      local counts = {}
      for _, au in ipairs(vim.api.nvim_get_autocmds({ group = 'bodging' })) do
        counts[au.event] = (counts[au.event] or 0) + 1
      end
      return counts
    end)
    eq({
      VimLeavePre = 1,
      SessionWritePost = 1,
      BufNew = 1,
      BufReadCmd = 1,
    }, counts)
  end)

  it('removes the previous lockfile on a second call', function()
    local locks = exec_lua(function()
      local cc = require('bodging')
      cc.setup()
      cc.start('claude')
      cc.setup()
      cc.start('claude')
      return vim.fn.readdir(vim.env.CLAUDE_CONFIG_DIR .. '/ide')
    end)
    eq(1, #locks)
  end)

  it('leaves one listening server after a second call', function()
    local n = exec_lua(function()
      local cc = require('bodging')
      cc.setup()
      cc.start('claude')
      cc.setup()
      cc.start('claude')
      local n = 0
      for _, kind in pairs(require('test.helpers').handles()) do
        n = n + (kind == 'tcp' and 1 or 0)
      end
      return n
    end)
    eq(1, n)
  end)

  it('replaces the configuration on a second call', function()
    local config = exec_lua(function()
      local cc = require('bodging')
      cc.setup({ cmd = { 'claude', '--verbose' }, on_busy = 'queue' })
      cc.setup({ cmd = { 'other' } })
      return { cmd = cc.configs.claude.cmd, on_busy = cc.configs.claude.on_busy }
    end)
    eq({ cmd = { 'other' }, on_busy = 'error' }, config)
  end)

  it('starts no server when validation fails', function()
    local n = exec_lua(function()
      local cc = require('bodging')
      cc.setup({ cmd = 'claude' })
      pcall(cc.open, 'claude')
      local n = 0
      for _, kind in pairs(require('test.helpers').handles()) do
        n = n + (kind == 'tcp' and 1 or 0)
      end
      return n
    end)
    eq(0, n)
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
    { 'active', { active = 'window' } },
    { 'active[2]', { active = { 'window', 'nope' } } },
    { 'active[1]', { active = { 1 } } },
    { 'root_markers[1]', { root_markers = { 1 } } },
    { 'show.window', { show = { window = 1 } } },
    { 'restore', { restore = 1 } },
    { 'restore.max_age', { restore = { max_age = '1d' } } },
    { 'editor', { editor = fn } },
    { 'editor.open', { editor = { open = 'split' } } },
    { 'ccd_dir', { ccd_dir = 1 } },
    { 'harness', { harness = 'codex' } },
    { 'command', { command = 'agent' } },
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
      active = { 'buffer', fn, 'project', 'pick' },
      root_markers = { '.git', 'Makefile' },
      show = { window = fn },
      restore = { max_age = 60 },
      editor = { open = fn },
      ccd_dir = '/tmp',
    })
    assert(err == nil, err)
  end)
end)
