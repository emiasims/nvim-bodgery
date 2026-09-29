local M = {}

--- @class bodgery.RestoreEntry
--- @field session_id string
--- @field cwd string
--- @field config? string config name
--- @field time integer when a session file last saved the terminal

--- @return string
function M.path()
  return vim.fs.joinpath(vim.fn.stdpath('state'), 'bodgery', 'terminals.json')
end

--- @return table<string, bodgery.RestoreEntry>
local function read()
  local f = io.open(M.path(), 'rb')
  if not f then
    return {}
  end
  local ok, entries = pcall(vim.json.decode, f:read('*a'))
  f:close()
  return ok and type(entries) == 'table' and entries or {}
end

--- @param entries table<string, bodgery.RestoreEntry>
local function write(entries)
  local path = M.path()
  vim.fn.mkdir(vim.fs.dirname(path), 'p')
  local tmp = path .. '.tmp'
  local f = assert(io.open(tmp, 'wb'))
  f:write(vim.json.encode(vim.tbl_isempty(entries) and vim.empty_dict() or entries))
  f:close()
  assert(vim.uv.fs_rename(tmp, path))
end

--- The config `name` names, or nil when there is none.
--- @param name any
--- @return bodgery.Config?
local function config(name)
  local ok, c = pcall(function()
    return require('bodgery').configs[name]
  end)
  return type(name) == 'string' and ok and c or nil
end

--- Records every agent terminal bound to a session, and drops entries older than their
--- config's `restore.max_age`.
function M.save()
  local entries = read()
  local now = os.time()
  local default = require('bodgery.config').defaults.restore.max_age
  for name, entry in pairs(entries) do
    local c = type(entry) == 'table' and config(entry.config)
    local max_age = c and c.restore.max_age or default
    if type(entry) ~= 'table' or now - (tonumber(entry.time) or 0) > max_age then
      entries[name] = nil
    end
  end
  for bufnr, term in pairs(require('bodgery.terminal').terminals) do
    if term.session_id then
      entries[vim.api.nvim_buf_get_name(bufnr)] =
        { session_id = term.session_id, cwd = term.cwd, config = term.config.name, time = now }
    end
  end
  write(entries)
end

--- `SessionWritePre`: moves windows showing agent terminals out of removed working
--- directories to their nearest existing parent, since the session's `:lcd` into one
--- aborts loading everything after it.
function M.before_save()
  local terminals = require('bodgery.terminal').terminals
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if terminals[vim.api.nvim_win_get_buf(win)] then
      vim.api.nvim_win_call(win, function()
        local dir = vim.fn.getcwd()
        if vim.fn.isdirectory(dir) == 0 and vim.fn.haslocaldir() == 1 then
          while vim.fn.isdirectory(dir) == 0 do
            dir = vim.fs.dirname(dir)
          end
          vim.cmd.lcd(vim.fn.fnameescape(dir))
        end
      end)
    end
  end
end

--- Whether a running Claude or another plugin terminal holds session `id`.
--- @param id string
--- @param harness table
--- @return boolean
local function held(id, harness)
  for _, term in pairs(require('bodgery.terminal').terminals) do
    if term.session_id == id then
      return true
    end
  end
  return harness.live()[id] ~= nil
end

--- Launches the agent in the restored buffer `bufnr`, resuming its session unless something
--- else holds it.
--- @param bufnr integer
--- @param entry bodgery.RestoreEntry
local function relaunch(bufnr, entry)
  local c = config(entry.config)
  if not c then
    vim.notify(
      ('bodgery: no config named %s to restore %s'):format(entry.config, entry.session_id),
      vim.log.levels.WARN
    )
    return
  end
  if vim.fn.isdirectory(entry.cwd) == 0 then
    vim.notify(
      ('bodgery: %s no longer exists, not restoring %s'):format(entry.cwd, entry.session_id),
      vim.log.levels.WARN
    )
    return
  end
  local harness = require('bodgery').harnesses[c.harness]
  local args
  if held(entry.session_id, harness) then
    vim.notify(
      ('bodgery: session %s is already open, starting a new conversation'):format(entry.session_id),
      vim.log.levels.WARN
    )
  else
    args = harness.resume_args(entry.session_id)
  end
  vim.api.nvim_buf_call(bufnr, function()
    local terminal = require('bodgery.terminal')
    terminal.open(c, { buf = true, cwd = entry.cwd, args = args })
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
    vim.b[ev.buf].bodgery_restore = entry
  end
end

--- `BufReadCmd` on `term://*`: relaunches a buffer `on_new` marked.
--- @param ev vim.api.keyset.create_autocmd.callback_args
function M.on_read(ev)
  local entry = vim.b[ev.buf].bodgery_restore
  if entry and vim.bo[ev.buf].channel == 0 then
    vim.b[ev.buf].bodgery_restore = nil
    vim.b[ev.buf].term_title = nil
    relaunch(ev.buf, entry)
  end
end

return M
