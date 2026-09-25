local helpers = require('test.helpers')
local exec_lua = require('nvim-test.helpers').exec_lua

describe('prompt editor', function()
  before_each(function()
    helpers.clear()
    exec_lua(function()
      _G.h = require('test.helpers')
      _G.before = h.handles()
      _G.cc = require('bodging')
      cc.setup({ cmd = h.fake_cmd() })
      cc.start('claude')
      _G.token = require('bodging.terminal').terminals[cc.open()].token

      _G.file = vim.fn.tempname()
      vim.fn.writefile({ 'draft' }, file)

      --- Runs the EDITOR wrapper on `file` the way Claude does; the result lands in `run.out`.
      function _G.run(tok)
        local run = {}
        vim.system({ h.root .. '/bin/bodging-editor', file }, {
          env = { BODGING_TOKEN = tok, CLAUDE_CODE_SSE_PORT = tostring(cc.server.port) },
        }, function(out)
          run.out = out
        end)
        return run
      end

      function _G.shown()
        local b = vim.fn.bufnr(file)
        return b ~= -1 and #vim.fn.win_findbuf(b) > 0
      end
    end)
  end)

  after_each(function()
    exec_lua(function()
      h.eq({}, h.stop_plugin(before), 'leaked handles')
    end)
  end)

  it('blocks until the buffer is hidden and leaves the edits in the file', function()
    exec_lua(function()
      vim.cmd.tabnew()
      vim.cmd.split()
      vim.cmd.tabprevious()
      local other_tab = h.layout()[2]
      local wins = #vim.api.nvim_tabpage_list_wins(0)

      local r = run(token)
      h.wait(shown, 'the draft in a window')
      h.eq(wins + 1, #vim.api.nvim_tabpage_list_wins(0))
      h.eq(vim.fn.bufnr(file), vim.api.nvim_get_current_buf())
      h.eq('bodge-prompt', vim.bo.filetype)
      vim.wait(100)
      h.eq(nil, r.out)

      vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'edited prompt' })
      vim.cmd.write()
      vim.cmd.quit()
      h.wait(function()
        return r.out
      end, 'the wrapper to exit')
      h.eq(0, r.out.code, r.out.stderr)
      h.eq({ 'edited prompt' }, vim.fn.readfile(file))
      h.eq(other_tab, h.layout()[2])
      h.eq(wins, #vim.api.nvim_tabpage_list_wins(0))
      h.wait(function()
        return vim.fn.bufnr(file) == -1 or not vim.api.nvim_buf_is_loaded(vim.fn.bufnr(file))
      end, 'the draft buffer to go')
    end)
  end)

  it('exits non-zero without opening anything for a bad token', function()
    exec_lua(function()
      local wins = #vim.api.nvim_list_wins()
      local r = run('wrong')
      h.wait(function()
        return r.out
      end, 'the wrapper to exit')
      assert(r.out.code ~= 0, 'expected a failure')
      h.eq(wins, #vim.api.nvim_list_wins())
      h.eq(-1, vim.fn.bufnr(file))
    end)
  end)

  it('opens the file through opts.editor.open', function()
    exec_lua(function()
      local got
      cc.configs.claude.editor.open = function(path)
        got = path
        vim.cmd.edit(path)
      end
      local prev = vim.api.nvim_get_current_buf()
      local r = run(token)
      h.wait(shown, 'the draft in a window')
      h.eq(vim.uv.fs_realpath(file), vim.uv.fs_realpath(got))
      vim.api.nvim_win_set_buf(0, prev)
      h.wait(function()
        return r.out
      end, 'the wrapper to exit')
      h.eq(0, r.out.code)
    end)
  end)
end)
