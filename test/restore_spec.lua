local helpers = require('test.helpers')
local exec_lua = require('nvim-test.helpers').exec_lua

--- Starts a child sharing `tmp` with the plugin set up.
--- @param tmp? string
--- @return string tmp
local function start(tmp)
  tmp = helpers.clear(tmp)
  exec_lua(function()
    _G.h = require('test.helpers')
    _G.before = h.handles()
    _G.cc = require('bodging')
    cc.setup({ cmd = h.fake_cmd() })
    _G.terminal = require('bodging.terminal')
    _G.restore = require('bodging.restore')

    function _G.state()
      return vim.json.decode(table.concat(vim.fn.readfile(restore.path()), '\n'))
    end

    --- Buffers with a running job, and whether the plugin registered them.
    function _G.jobs()
      local out = {}
      for _, b in ipairs(vim.api.nvim_list_bufs()) do
        if vim.bo[b].channel ~= 0 then
          out[#out + 1] = terminal.terminals[b] and 'claude' or 'other'
        end
      end
      table.sort(out)
      return out
    end
  end)
  return tmp
end

--- In a first child, opens a Claude terminal bound to `sid` and a plain terminal, and
--- writes a session file; returns the Claude terminal's buffer name.
--- @param write? fun(path: string) writes the session file, default `:mksession`
--- @return string name
--- @return string tmp
local function save(write)
  local tmp = start()
  return exec_lua(function(path, write_fn)
    local bufnr = cc.open()
    terminal.terminals[bufnr].session_id = 'sid-1'
    vim.cmd('botright split | terminal sleep 100')
    if write_fn then
      loadstring(write_fn)(path)
    else
      vim.cmd.mksession({ path, bang = true })
    end
    return vim.api.nvim_buf_get_name(bufnr)
  end, tmp .. '/session.vim', write and string.dump(write)),
    tmp
end

describe('session restore', function()
  after_each(function()
    exec_lua(function()
      h.eq({}, h.stop_plugin(before), 'leaked handles')
    end)
  end)

  it('relaunches a saved Claude terminal once with --resume', function()
    local name, tmp = save()
    exec_lua(function(n)
      h.eq('sid-1', state()[n].session_id)
    end, name)

    start(tmp)
    exec_lua(function(session, n, record_dir)
      vim.cmd.source(session)
      h.eq({ 'claude', 'other' }, jobs())
      local bufnr = vim.fn.bufnr(n)
      local term = assert(terminal.terminals[bufnr], 'restored buffer is not a Claude terminal')
      local argv = h.record(bufnr).argv
      h.eq({ '--resume', 'sid-1' }, vim.list_slice(argv, #argv - 1))
      h.eq('sid-1', term.session_id)
      -- Neovim's handler would have run fake-claude without a token
      h.eq(0, vim.fn.filereadable(record_dir .. '/none.json'))

      vim.cmd.mksession({ session, bang = true })
      h.eq('sid-1', state()[vim.api.nvim_buf_get_name(bufnr)].session_id)
    end, tmp .. '/session.vim', name, tmp .. '/record')
  end)

  it('restores from a session file written to a temporary path and moved', function()
    local name, tmp = save(function(path)
      local tmp_path = path .. '.tmp'
      vim.cmd.mksession({ tmp_path, bang = true })
      assert(vim.uv.fs_rename(tmp_path, path))
    end)
    start(tmp)
    exec_lua(function(session, n)
      vim.cmd.source(session)
      local argv = h.record(vim.fn.bufnr(n)).argv
      h.eq({ '--resume', 'sid-1' }, vim.list_slice(argv, #argv - 1))
    end, tmp .. '/session.vim', name)
  end)

  it('starts a new conversation when the session is already open', function()
    local name, tmp = save()
    start(tmp)
    exec_lua(function(session, n)
      local rec = { pid = vim.fn.getpid(), sessionId = 'sid-1', status = 'idle' }
      local dir = vim.env.CLAUDE_CONFIG_DIR .. '/sessions'
      vim.fn.mkdir(dir, 'p')
      vim.fn.writefile({ vim.json.encode(rec) }, ('%s/%d.json'):format(dir, rec.pid))
      local notes = {}
      vim.notify = function(msg)
        notes[#notes + 1] = msg
      end

      vim.cmd.source(session)
      local bufnr = vim.fn.bufnr(n)
      h.eq(false, vim.list_contains(h.record(bufnr).argv, '--resume'))
      h.eq(nil, terminal.terminals[bufnr].session_id)
      h.eq({ 'bodging: session sid-1 is already open, starting a new conversation' }, notes)
    end, tmp .. '/session.vim', name)
  end)

  it('drops entries older than max_age on the next write', function()
    start()
    exec_lua(function()
      vim.fn.mkdir(vim.fs.dirname(restore.path()), 'p')
      vim.fn.writefile({
        vim.json.encode({
          ['term://old//1:claude'] = { session_id = 'old', cwd = '/', time = 0 },
          ['term://new//2:claude'] = { session_id = 'new', cwd = '/', time = os.time() },
        }),
      }, restore.path())
      vim.cmd.mksession({ vim.fn.tempname(), bang = true })
      h.eq({ 'term://new//2:claude' }, vim.tbl_keys(state()))
    end)
  end)
end)
