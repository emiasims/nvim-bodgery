local M = {}

--- @class claude-code.RestoreEntry
--- @field session_id string
--- @field cwd string
--- @field config? string config name
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

--- Records every Claude terminal bound to a session, and drops entries older than the
--- default config's `restore.max_age`.
function M.save()
  local entries = read()
  local now = os.time()
  local cc = require('claude-code')
  local max_age = cc.configs[cc.default].restore.max_age
  for name, entry in pairs(entries) do
    if type(entry) ~= 'table' or now - (tonumber(entry.time) or 0) > max_age then
      entries[name] = nil
    end
  end
  for bufnr, term in pairs(require('claude-code.terminal').terminals) do
    if term.session_id then
      entries[vim.api.nvim_buf_get_name(bufnr)] =
        { session_id = term.session_id, cwd = term.cwd, config = term.config.name, time = now }
    end
  end
  write(entries)
end

--- Whether a running Claude or another plugin terminal holds session `id`.
--- @param id string
--- @param harness table
--- @return boolean
local function held(id, harness)
  for _, term in pairs(require('claude-code.terminal').terminals) do
    if term.session_id == id then
      return true
    end
  end
  return harness.live()[id] ~= nil
end

--- Launches Claude in the restored buffer `bufnr`, resuming its session unless something
--- else holds it.
--- @param bufnr integer
--- @param entry claude-code.RestoreEntry
local function relaunch(bufnr, entry)
  local cc = require('claude-code')
  local harness = cc.harnesses[cc.configs[entry.config or cc.default].harness]
  local args
  if held(entry.session_id, harness) then
    vim.notify(
      ('claude-code: session %s is already open, starting a new conversation'):format(entry.session_id),
      vim.log.levels.WARN
    )
  else
    args = harness.resume(entry.session_id).args
  end
  vim.api.nvim_buf_call(bufnr, function()
    local terminal = require('claude-code.terminal')
    terminal.open({ buf = true, cwd = entry.cwd, args = args, config = entry.config })
    if args then
      terminal.terminals[bufnr].session_id = entry.session_id
    end
  end)
end

--- `BufNew` on `term://*`: marks buffers named in the state file for relaunch.
--- @param ev vim.api.keyset.create_autocmd.callback_args
function M.on_new(ev)
  local entry = read()[ev.match]
  if entry then
    -- Neovim's own term:// handler skips buffers with a title
    vim.b[ev.buf].term_title = ''
    vim.b[ev.buf].claude_code_restore = entry
  end
end

--- `BufReadCmd` on `term://*`: relaunches a buffer `on_new` marked.
--- @param ev vim.api.keyset.create_autocmd.callback_args
function M.on_read(ev)
  local entry = vim.b[ev.buf].claude_code_restore
  if entry and vim.bo[ev.buf].channel == 0 then
    vim.b[ev.buf].claude_code_restore = nil
    vim.b[ev.buf].term_title = nil
    relaunch(ev.buf, entry)
  end
end

return M
