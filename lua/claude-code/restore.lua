local M = {}

--- @class claude-code.RestoreEntry
--- @field session_id string
--- @field cwd string
--- @field time integer when a session file last saved the terminal

--- @return string
function M.path()
  return vim.fs.joinpath(vim.fn.stdpath('state'), 'claude-code', 'terminals.json')
end

--- @return table<string, claude-code.RestoreEntry>
local function read()
  local f = io.open(M.path(), 'rb')
  if not f then
    return {}
  end
  local ok, entries = pcall(vim.json.decode, f:read('*a'))
  f:close()
  return ok and type(entries) == 'table' and entries or {}
end

--- @param entries table<string, claude-code.RestoreEntry>
local function write(entries)
  local path = M.path()
  vim.fn.mkdir(vim.fs.dirname(path), 'p')
  local tmp = path .. '.tmp'
  local f = assert(io.open(tmp, 'wb'))
  f:write(vim.json.encode(vim.tbl_isempty(entries) and vim.empty_dict() or entries))
  f:close()
  assert(vim.uv.fs_rename(tmp, path))
end

--- Records every Claude terminal bound to a session, and drops entries older than
--- `opts.restore.max_age`.
function M.save()
  local entries = read()
  local now = os.time()
  local max_age = require('claude-code').config.restore.max_age
  for name, entry in pairs(entries) do
    if type(entry) ~= 'table' or now - (tonumber(entry.time) or 0) > max_age then
      entries[name] = nil
    end
  end
  for bufnr, term in pairs(require('claude-code.terminal').terminals) do
    if term.session_id then
      entries[vim.api.nvim_buf_get_name(bufnr)] =
        { session_id = term.session_id, cwd = term.cwd, time = now }
    end
  end
  write(entries)
end

--- Whether a running Claude or another plugin terminal holds session `id`.
--- @param id string
--- @return boolean
local function held(id)
  for _, term in pairs(require('claude-code.terminal').terminals) do
    if term.session_id == id then
      return true
    end
  end
  return require('claude-code').harness.live()[id] ~= nil
end

--- Launches Claude in the restored buffer `bufnr`, resuming its session unless something
--- else holds it.
--- @param bufnr integer
--- @param entry claude-code.RestoreEntry
local function relaunch(bufnr, entry)
  local cc = require('claude-code')
  local args
  if held(entry.session_id) then
    vim.notify(
      ('claude-code: session %s is already open, starting a new conversation'):format(entry.session_id),
      vim.log.levels.WARN
    )
  else
    args = cc.harness.resume(entry.session_id).args
  end
  vim.api.nvim_buf_call(bufnr, function()
    local terminal = require('claude-code.terminal')
    terminal.open({ buf = true, cwd = entry.cwd, args = args })
    if args then
      terminal.terminals[bufnr].session_id = entry.session_id
    end
  end)
end

--- @param group integer
function M.attach(group)
  vim.api.nvim_create_autocmd('SessionWritePost', { group = group, callback = M.save })
  vim.api.nvim_create_autocmd('BufNew', {
    group = group,
    pattern = 'term://*',
    callback = function(ev)
      local entry = read()[ev.match]
      if entry then
        -- Neovim's own term:// handler skips buffers with a title
        vim.b[ev.buf].term_title = ''
        vim.b[ev.buf].claude_code_restore = entry
      end
    end,
  })
  vim.api.nvim_create_autocmd('BufReadCmd', {
    group = group,
    pattern = 'term://*',
    nested = true,
    callback = function(ev)
      local entry = vim.b[ev.buf].claude_code_restore
      if entry and vim.bo[ev.buf].channel == 0 then
        vim.b[ev.buf].claude_code_restore = nil
        vim.b[ev.buf].term_title = nil
        relaunch(ev.buf, entry)
      end
    end,
  })
end

return M
