local helpers = require('test.helpers')
local exec_lua = require('nvim-test.helpers').exec_lua

--- Buffer numbers the nvim_buffers handler returns for `scope`.
local function bufnrs(scope)
  return exec_lua(function(s)
    local res = require('bodgery.tools.buffers').tool.handler({ scope = s })
    return type(res) == 'string' and res or vim.tbl_map(function(b)
      return b.bufnr
    end, res)
  end, scope)
end

describe('nvim_buffers', function()
  before_each(function()
    helpers.clear()
    -- 1: listed, shown in tab 1. 2: listed, hidden. 3: unlisted help-like buffer in
    -- tab 2. 4: listed, shown in tab 2.
    exec_lua(function()
      vim.api.nvim_buf_set_lines(1, 0, -1, false, { 'a', 'b', 'c' })
      vim.cmd('edit /tmp/bodgery-two | buffer 1')
      _G.unlisted = vim.api.nvim_create_buf(false, true)
      vim.cmd('tabnew /tmp/bodgery-four')
      vim.cmd('split | buffer ' .. unlisted)
    end)
  end)

  it('filters by scope', function()
    helpers.eq({ 1, 2, 4 }, bufnrs('listed'))
    helpers.eq({ 1, 2, 4 }, bufnrs(nil))
    helpers.eq({ 3 }, bufnrs('unlisted'))
    helpers.eq({ 1, 2, 3, 4 }, bufnrs('all'))
    helpers.eq({ 1, 3, 4 }, bufnrs('visible'))
    helpers.eq({ 3, 4 }, bufnrs('tab'))
    exec_lua(function()
      vim.cmd('tabfirst')
    end)
    helpers.eq({ 1 }, bufnrs('tab'))
  end)

  it('describes each buffer the way :ls flags it', function()
    local bufs = exec_lua(function()
      vim.cmd('tabfirst')
      local out = {}
      for _, b in ipairs(require('bodgery.tools.buffers').list('all')) do
        b.lastused = nil
        out[b.bufnr] = b
      end
      return out
    end)
    helpers.eq({
      bufnr = 1,
      name = '[No Name]',
      current = true,
      alternate = false,
      listed = true,
      loaded = true,
      hidden = false,
      modified = true,
      modifiable = true,
      readonly = false,
      filetype = '',
      buftype = '',
      lines = 3,
      line = 1,
      windows = { { winid = 1000, tab = 1 } },
    }, bufs[1])
    helpers.eq({ true, true, false }, { bufs[2].alternate, bufs[2].hidden, bufs[2].current })
    helpers.eq({ '[Scratch]', false, 'nofile' }, { bufs[3].name, bufs[3].listed, bufs[3].buftype })
    helpers.eq({ { winid = 1002, tab = 2 } }, bufs[3].windows)
  end)

  it("reports a terminal's job state", function()
    local jobs = exec_lua(function()
      vim.cmd('terminal sleep 60')
      local running = vim.api.nvim_get_current_buf()
      vim.cmd('terminal true')
      local finished = vim.api.nvim_get_current_buf()
      vim.fn.jobwait({ vim.bo[finished].channel }, 1000)
      local out = {}
      for _, b in ipairs(require('bodgery.tools.buffers').list('all')) do
        out[b.bufnr] = b.job
      end
      vim.fn.jobstop(vim.bo[running].channel)
      return { out[running], out[finished], out[1] or 'nil' }
    end)
    helpers.eq({ 'running', 'finished', 'nil' }, jobs)
  end)

  it('reports an empty scope and rejects an unknown one', function()
    exec_lua(function()
      vim.cmd('bwipeout ' .. unlisted)
    end)
    helpers.eq('no buffers', bufnrs('unlisted'))
    local ok, err = pcall(bufnrs, 'nope')
    helpers.eq(false, ok)
    assert(tostring(err):find('unknown scope "nope"', 1, true), err)
  end)
end)
