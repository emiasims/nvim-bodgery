local helpers = require('test.helpers')
local exec_lua = require('nvim-test.helpers').exec_lua

describe('diff', function()
  before_each(function()
    helpers.clear()
    exec_lua(function()
      _G.h = require('test.helpers')
      _G.before = h.handles()
      _G.cc = require('claude-code')
      _G.diff = require('claude-code.harness.claude.diff')
      cc.setup({ cmd = h.fake_cmd() })
      _G.client = h.ws_connect(cc.server.port, cc.harness.state.auth_token)

      _G.dir = vim.fn.tempname()
      vim.fn.mkdir(dir, 'p')
      _G.path = dir .. '/a.txt'
      vim.fn.writefile({ 'one', 'A C', 'three', 'four' }, path)

      local id = 0
      --- Sends openDiff and returns its request id without waiting for the reply.
      function _G.open_diff(tab, contents, file)
        id = id + 1
        file = file or path
        local prev = diff.pending[tab]
        client:send_text(vim.json.encode({
          jsonrpc = '2.0',
          id = id,
          method = 'tools/call',
          params = {
            name = 'openDiff',
            arguments = {
              old_file_path = file,
              new_file_path = file,
              new_file_contents = contents,
              tab_name = tab,
            },
          },
        }))
        h.wait(function()
          return diff.pending[tab] and diff.pending[tab] ~= prev
        end, 'openDiff ' .. tab)
        return id
      end

      --- Calls an IDE tool and returns the texts of its result.
      function _G.call(name, args)
        id = id + 1
        client:send_text(vim.json.encode({
          jsonrpc = '2.0',
          id = id,
          method = 'tools/call',
          params = { name = name, arguments = args or vim.empty_dict() },
        }))
        return id
      end

      --- The next reply as `{ id, texts... }`.
      function _G.reply()
        local msg = client:recv_json()
        local out = { msg.id }
        for _, c in ipairs(msg.result.content) do
          out[#out + 1] = c.text
        end
        return out
      end

      --- Fails if any reply is still unread, since a ping's reply must come next.
      function _G.no_more_replies()
        id = id + 1
        client:send_text(vim.json.encode({ jsonrpc = '2.0', id = id, method = 'ping' }))
        h.eq(id, client:recv_json().id)
      end

      --- Waits for the scheduled cleanup of `d`.
      function _G.cleaned(d)
        h.wait(function()
          return not vim.api.nvim_buf_is_valid(d.bufnr)
        end, 'cleanup')
      end
    end)
  end)

  after_each(function()
    exec_lua(function()
      client:close()
      h.eq({}, h.stop_plugin(before), 'leaked handles')
    end)
  end)

  it('accepts with :w, returning the edits the user made', function()
    exec_lua(function()
      vim.cmd.edit(path)
      local file_buf = vim.api.nvim_get_current_buf()
      local layout = h.layout()
      local rid = open_diff('t', 'one\nA B C\nthree\n')
      local d = diff.pending.t
      h.eq(d.bufnr, vim.api.nvim_get_current_buf())

      vim.api.nvim_buf_set_lines(d.bufnr, 0, 1, false, { 'ONE' })
      vim.cmd.write()
      h.eq({ rid, 'FILE_SAVED', 'ONE\nA B C\nthree\n' }, reply())
      no_more_replies()
      cleaned(d)
      h.eq(file_buf, vim.api.nvim_get_current_buf())
      h.eq(layout, h.layout())
    end)
  end)

  it('keeps a missing final newline', function()
    exec_lua(function()
      local rid = open_diff('t', 'one\nno newline')
      vim.cmd.write()
      h.eq({ rid, 'FILE_SAVED', 'one\nno newline' }, reply())
    end)
  end)

  it('rejects once on :q, :bdelete, and :tabclose', function()
    exec_lua(function()
      cc.open()
      local layout = h.layout()

      local rid = open_diff('q', 'x\n')
      local d = diff.pending.q
      vim.api.nvim_set_current_win(d.win)
      vim.cmd.quit()
      h.eq({ rid, 'DIFF_REJECTED', 'q' }, reply())
      cleaned(d)
      h.eq(layout, h.layout())

      rid = open_diff('bd', 'x\n')
      d = diff.pending.bd
      vim.cmd.bdelete(d.bufnr)
      h.eq({ rid, 'DIFF_REJECTED', 'bd' }, reply())
      cleaned(d)
      h.eq(layout, h.layout())

      vim.cmd.tabnew()
      rid = open_diff('tab', 'x\n')
      d = diff.pending.tab
      vim.cmd.tabclose()
      h.eq({ rid, 'DIFF_REJECTED', 'tab' }, reply())
      cleaned(d)
      h.eq(layout, h.layout())
      no_more_replies()
    end)
  end)

  it('rejects the first diff when a second opens with the same tab name', function()
    exec_lua(function()
      local first = open_diff('t', 'first\n')
      local d1 = diff.pending.t
      local second = open_diff('t', 'second\n', dir .. '/b.txt')
      h.eq({ first, 'DIFF_REJECTED', 't' }, reply())
      h.eq(true, diff.pending.t ~= d1)
      h.eq({ 'second' }, vim.api.nvim_buf_get_lines(diff.pending.t.bufnr, 0, -1, false))

      local closed = call('close_tab', { tab_name = 't' })
      local replies = { reply(), reply() }
      table.sort(replies, function(a, b)
        return a[1] < b[1]
      end)
      h.eq({ { second, 'TAB_CLOSED', 't' }, { closed, 'TAB_CLOSED' } }, replies)
    end)
  end)

  it('closes every diff with closeAllDiffTabs', function()
    exec_lua(function()
      open_diff('a', 'a\n')
      -- a diff shown over another hides it, which rejects it
      vim.cmd.split()
      open_diff('b', 'b\n', dir .. '/b.txt')
      local rid = call('closeAllDiffTabs')
      local texts = {}
      for _ = 1, 3 do
        local r = reply()
        texts[#texts + 1] = r[1] == rid and r[2] or r[2] .. ' ' .. r[3]
      end
      table.sort(texts)
      h.eq({ 'CLOSED_2_DIFF_TABS', 'TAB_CLOSED a', 'TAB_CLOSED b' }, texts)
      h.eq({}, diff.pending)
    end)
  end)

  it('shows a new file as added lines', function()
    exec_lua(function()
      local new_path = dir .. '/new.txt'
      local rid = open_diff('n', 'a\nb\n', new_path)
      local d = diff.pending.n
      local ns = vim.api.nvim_get_namespaces()['claude-code.diff']
      local marks = vim.api.nvim_buf_get_extmarks(d.bufnr, ns, 0, -1, { details = true })
      h.eq(
        { { 0, 'DiffAdd' }, { 1, 'DiffAdd' } },
        vim.tbl_map(function(m)
          return { m[2], m[4].line_hl_group }
        end, marks)
      )
      vim.cmd.write()
      h.eq({ rid, 'FILE_SAVED', 'a\nb\n' }, reply())
      h.eq(nil, vim.uv.fs_stat(new_path))
    end)
  end)

  it('marks changes inline, or as removed and added lines', function()
    exec_lua(function()
      local ns = vim.api.nvim_get_namespaces()['claude-code.diff']
      local function marks(bufnr)
        local out = {}
        for _, m in ipairs(vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, { details = true })) do
          local det = m[4]
          out[#out + 1] = {
            m[2],
            m[3],
            det.line_hl_group or det.hl_group,
            det.end_col,
            det.virt_text and det.virt_text[1][1],
            det.virt_lines and det.virt_lines[1][1][1]:gsub('%s+$', ''),
          }
        end
        return out
      end

      open_diff('i', 'one\nA B C\nnew line\nthree\n')
      h.eq({
        { 1, 0, 'DiffChange', 0 },
        { 1, 2, 'DiffText', 4 },
        { 2, 0, 'DiffAdd' },
        { 3, 0, nil, nil, nil, 'four' },
      }, marks(diff.pending.i.bufnr))
      vim.cmd.bdelete(diff.pending.i.bufnr)
      reply()

      open_diff('d', 'one\nA\nthree\nfour\n')
      h.eq({ { 1, 0, 'DiffChange', 0 }, { 1, 1, nil, nil, ' C' } }, marks(diff.pending.d.bufnr))
      vim.cmd.bdelete(diff.pending.d.bufnr)
      reply()

      cc.config.diff.inline = false
      open_diff('l', 'one\nA B C\nthree\nfour\n')
      h.eq(
        { { 1, 0, 'DiffAdd', nil, nil, nil }, { 1, 0, nil, nil, nil, 'A C' } },
        marks(diff.pending.l.bufnr)
      )
    end)
  end)

  it('closes the diff without a reply when the client disconnects', function()
    exec_lua(function()
      vim.cmd.edit(path)
      local file_buf = vim.api.nvim_get_current_buf()
      open_diff('t', 'x\n')
      local d = diff.pending.t
      client:close()
      cleaned(d)
      h.eq({}, diff.pending)
      h.eq(file_buf, vim.api.nvim_get_current_buf())
    end)
  end)

  it('draws inserted characters over the changed line', function()
    local Screen = require('nvim-test.screen')
    local screen = Screen.new(30, 8)
    screen:attach()
    exec_lua(function()
      vim.fn.writefile({ '1', '2', '4', '6', '8' }, path)
      open_diff('t', '1\n2\n3\n4 and more\n8\n10\n')
      vim.cmd('normal! gg')
    end)
    screen:expect({
      grid = [[
      ^1                             |
      2                             |
      {1:3                             }|
      {2:4}{3: and more}{2:                    }|
      {4:6                             }|
      8                             |
      {1:10                            }|
                                    |
    ]],
      attr_ids = {
        [1] = { background = Screen.colors.NvimLightGreen, foreground = Screen.colors.NvimDarkGrey1 },
        [2] = { background = Screen.colors.NvimLightGrey4, foreground = Screen.colors.NvimDarkGrey1 },
        [3] = { background = Screen.colors.NvimLightCyan, foreground = Screen.colors.NvimDarkGrey1 },
        [4] = { foreground = Screen.colors.NvimDarkRed, bold = true },
      },
    })
  end)

  describe('window', function()
    it('opens a vertical split when Claude is alone, following splitright', function()
      exec_lua(function()
        for _, right in ipairs({ false, true }) do
          vim.cmd('silent! %bwipeout!')
          vim.o.splitright = right
          local claude_win = vim.api.nvim_get_current_win()
          cc.open()
          open_diff('t', 'x\n')
          local d = diff.pending.t
          h.eq(true, d.created)
          h.eq({
            'row',
            { { 'leaf', right and claude_win or d.win }, { 'leaf', right and d.win or claude_win } },
          }, vim.fn.winlayout())
          h.eq(claude_win, vim.api.nvim_get_current_win())
          vim.cmd.bdelete(d.bufnr)
          reply()
          cleaned(d)
          h.eq({ 'leaf', claude_win }, vim.fn.winlayout())
        end
      end)
    end)

    it('uses the other window when there are two', function()
      exec_lua(function()
        vim.cmd.edit(path)
        local other = vim.api.nvim_get_current_win()
        vim.cmd.vsplit()
        cc.open()
        open_diff('t', 'x\n')
        h.eq(other, diff.pending.t.win)
        h.eq(false, diff.pending.t.created)
      end)
    end)

    it('uses the window nearest Claude in the layout', function()
      exec_lua(function()
        vim.o.splitright = false
        vim.o.splitbelow = false
        vim.cmd.edit(path)
        vim.cmd.vsplit()
        vim.cmd.split()
        local top = vim.api.nvim_get_current_win()
        vim.cmd.wincmd('j')
        local below = vim.api.nvim_get_current_win()
        vim.cmd.wincmd('l')
        vim.cmd.split()
        -- right column: two windows, Claude in the bottom one
        vim.cmd.wincmd('j')
        cc.open()
        local right_top = vim.fn.win_getid(vim.fn.winnr('k'))
        open_diff('t', 'x\n')
        h.eq(right_top, diff.pending.t.win)
        h.eq(true, top ~= right_top and below ~= right_top)
      end)
    end)

    it('uses opts.diff.window', function()
      exec_lua(function()
        vim.cmd.split()
        local chosen = vim.api.nvim_get_current_win()
        vim.cmd.wincmd('j')
        cc.config.diff.window = function()
          return chosen
        end
        open_diff('t', 'x\n')
        h.eq(chosen, diff.pending.t.win)
      end)
    end)
  end)
end)
