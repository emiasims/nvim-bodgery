local helpers = require('test.helpers')
local exec_lua = require('nvim-test.helpers').exec_lua

--- Calls built-in tool `name`'s handler in the child, returning `ok, result`.
local function call(name, args)
  return exec_lua(function(n, a)
    local tools = {
      nvim_messages = require('bodgery.tools.messages').tool,
      nvim_quickfix = require('bodgery.tools.quickfix').tool,
      nvim_rpc_read = require('bodgery.tools.rpc').tools.nvim_rpc_read,
      nvim_rpc_write = require('bodgery.tools.rpc').tools.nvim_rpc_write,
    }
    return pcall(tools[n].handler, a)
  end, name, args)
end

--- The result of a call that must succeed.
local function ok(name, args)
  local success, result = call(name, args)
  assert(success, result)
  return result
end

--- The error message of a call that must fail.
local function fails(name, args)
  local success, err = call(name, args)
  helpers.eq(false, success)
  return err
end

describe('nvim_messages', function()
  before_each(function()
    helpers.clear()
    exec_lua(function()
      vim.cmd('messages clear')
    end)
  end)

  it('returns the history, or its most recent entries', function()
    helpers.eq('no messages', ok('nvim_messages', {}))
    exec_lua(function()
      vim.cmd.echomsg('"one"')
      vim.cmd.echomsg('"two"')
    end)
    helpers.eq('one\ntwo', ok('nvim_messages', {}))
    helpers.eq('two', ok('nvim_messages', { count = 1 }))
  end)
end)

describe('nvim_quickfix', function()
  before_each(function()
    helpers.clear()
    exec_lua(function(root)
      local items = {}
      for i = 1, 3 do
        items[i] = { filename = root .. '/q' .. i, lnum = i, col = 2, text = 'entry ' .. i, type = 'E' }
      end
      vim.fn.setqflist({}, ' ', { title = 'mine', items = items })
      vim.fn.setloclist(0, {}, ' ', { title = 'local', items = { items[3] } })
    end, helpers.root)
  end)

  it('returns one page of the list with its size and current entry', function()
    helpers.eq({
      title = 'mine',
      size = 3,
      idx = 1,
      items = {
        {
          index = 2,
          filename = helpers.root .. '/q2',
          lnum = 2,
          end_lnum = 0,
          col = 2,
          end_col = 0,
          type = 'E',
          text = 'entry 2',
          valid = true,
        },
      },
    }, ok('nvim_quickfix', { offset = 1, limit = 1 }))
    helpers.eq(3, #ok('nvim_quickfix', {}).items)
    helpers.eq({}, ok('nvim_quickfix', { offset = 3 }).items)
  end)

  it("reads a window's location list", function()
    local loc = ok('nvim_quickfix', { list = 'location' })
    helpers.eq({ 'local', 1, helpers.root .. '/q3' }, { loc.title, loc.size, loc.items[1].filename })
    helpers.eq('no window 9999', fails('nvim_quickfix', { list = 'location', window = 9999 }))
  end)
end)

describe('rpc tools', function()
  before_each(function()
    helpers.clear()
    exec_lua(function()
      vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'a', 'b' })
    end)
  end)

  it('splits the API on the verb in the function name', function()
    local split = exec_lua(function()
      local rpc = require('bodgery.tools.rpc')
      return vim.tbl_map(rpc.is_read, {
        'nvim_get_mode',
        'nvim_buf_get_lines',
        'nvim_list_bufs',
        'nvim_win_is_valid',
        'nvim_parse_cmd',
        'nvim_buf_set_lines',
        'nvim_exec_lua',
        'nvim_set_current_line',
      })
    end)
    helpers.eq({ true, true, true, true, true, false, false, false }, split)
  end)

  it('calls read functions on nvim_rpc_read and the rest on nvim_rpc_write', function()
    helpers.eq(
      '["a","b"]',
      ok('nvim_rpc_read', { method = 'nvim_buf_get_lines', params = { 0, 0, -1, false } })
    )
    helpers.eq(
      'nvim_buf_set_lines is not a read-only function, use nvim_rpc_write',
      fails('nvim_rpc_read', { method = 'nvim_buf_set_lines', params = { 0, 0, -1, false, { 'c' } } })
    )
    helpers.eq(
      'null',
      ok('nvim_rpc_write', { method = 'nvim_buf_set_lines', params = { 0, 0, 1, false, { 'c' } } })
    )
    helpers.eq('3', ok('nvim_rpc_write', { method = 'nvim_exec_lua', params = { 'return 1 + 2', {} } }))
    helpers.eq(
      'nvim_get_mode is not a writing function, use nvim_rpc_read',
      fails('nvim_rpc_write', { method = 'nvim_get_mode' })
    )
    helpers.eq(
      { 'c', 'b' },
      exec_lua(function()
        return vim.api.nvim_buf_get_lines(0, 0, -1, false)
      end)
    )
  end)

  it('rejects unknown functions and encodes Lua callbacks as text', function()
    helpers.eq('no API function "vim_command"', fails('nvim_rpc_write', { method = 'vim_command' }))
    local callback = exec_lua(function()
      vim.keymap.set('n', '<F2>', function() end)
      local maps = vim.json.decode(require('bodgery.tools.rpc').call(true, 'nvim_get_keymap', { 'n' }))
      return vim.iter(maps):find(function(m)
        return m.lhs == '<F2>'
      end).callback
    end)
    assert(callback:find('^function: '), callback)
  end)
end)
