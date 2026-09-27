local helpers = require('test.helpers')
local exec_lua = require('nvim-test.helpers').exec_lua
local Screen = require('nvim-test.screen')

--- Calls the nvim_screen handler in the child and returns its result. The child redraws
--- only between requests, so the call is started, then polled from here.
local function call(args)
  exec_lua(function(a)
    _G.result = nil
    require('bodgery.tools.screen').tool.handler(a)(function(value)
      _G.result = value
    end)
  end, args)
  for _ = 1, 200 do
    local result = exec_lua(function()
      return _G.result
    end)
    if result then
      return result
    end
    vim.uv.sleep(10)
  end
  error('nvim_screen did not reply')
end

describe('nvim_screen', function()
  before_each(function()
    helpers.clear()
    Screen.new(40, 6):attach()
    exec_lua(function()
      _G.h = require('test.helpers')
      _G.before = h.handles()
      vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'hello', 'world 世界' })
      vim.cmd('vsplit')
      vim.cmd.highlight('Foo guifg=red')
      vim.fn.matchadd('Foo', 'world')
    end)
  end)

  after_each(function()
    exec_lua(function()
      h.eq({}, h.leaked(before), 'leaked handles')
    end)
  end)

  it('returns every screen row as text, with wide characters in place', function()
    helpers.eq(
      table.concat({
        'hello               │hello',
        'world 世界          │world 世界',
        '~                   │~',
        '~                   │~',
        '[No Name] [+]        [No Name] [+]',
        '',
      }, '\n'),
      call({})
    )
  end)

  it('returns highlight group runs in screen columns', function()
    local screen = call({ highlights = true })
    helpers.eq('world 世界          │world 世界', screen.lines[2])
    -- the match is window-local, so only the left window's "world" is highlighted
    helpers.eq({
      { 1, 21, 21, 'WinSeparator' },
      { 2, 1, 5, 'Foo' },
      { 2, 21, 21, 'WinSeparator' },
      { 3, 1, 20, 'EndOfBuffer' },
      { 3, 21, 21, 'WinSeparator' },
      { 3, 22, 40, 'EndOfBuffer' },
      { 4, 1, 20, 'EndOfBuffer' },
      { 4, 21, 21, 'WinSeparator' },
      { 4, 22, 40, 'EndOfBuffer' },
      { 5, 1, 21, 'StatusLine' },
      { 5, 22, 40, 'StatusLineNC' },
      { 6, 1, 40, 'MsgArea' },
    }, screen.highlights)
  end)

  it('reports a screen that is not drawn in time as an error', function()
    exec_lua(function()
      require('bodgery.tools.screen').timeout = 0
    end)
    local result = call({})
    helpers.eq(true, result.isError)
    helpers.eq('screen not drawn within 0 ms', result.content[1].text)
  end)
end)
