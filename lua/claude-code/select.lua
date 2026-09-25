local M = {}

--- @param sec integer seconds since the epoch
--- @return string
local function ago(sec)
  local d = os.time() - sec
  if d < 3600 then
    return ('%dm ago'):format(math.floor(d / 60))
  elseif d < 86400 then
    return ('%dh ago'):format(math.floor(d / 3600))
  end
  return ('%dd ago'):format(math.floor(d / 86400))
end

--- The session of the active terminal, or `session_id` when given.
--- @param session_id? string
--- @return string
local function current_session(session_id)
  if session_id then
    return session_id
  end
  local term = require('claude-code.terminal').active()
  return term.session_id or error('claude-code: the active terminal has no session yet', 0)
end

--- Shows the session in the terminal holding it, or resumes it in the active terminal,
--- or in a new terminal in the current window when there is no active terminal.
--- @param s claude-code.Session
local function open_session(s)
  local cc = require('claude-code')
  if s.bufnr and vim.api.nvim_buf_is_valid(s.bufnr) then
    vim.api.nvim_win_set_buf(0, s.bufnr)
  elseif pcall(require('claude-code.terminal').active) then
    cc.switch(s.id)
  else
    cc.switch(s.id, { new = true })
  end
end

--- @class claude-code.PickOpts
--- @field on_choice? fun(item: any) replaces the default action

--- Picks a session started in `opts.cwd` (default: the current directory), leaving out
--- archived ones.
--- @param opts? claude-code.PickOpts|{ cwd?: string }
function M.sessions(opts)
  opts = opts or {}
  local items = {}
  for s in require('claude-code').sessions({ cwd = opts.cwd or vim.fn.getcwd(), archived = false }) do
    items[#items + 1] = s
  end
  vim.ui.select(items, {
    prompt = 'Claude session',
    kind = 'claude-code.session',
    format_item = function(s)
      local mark = s.bufnr and '* ' or s.live and '+ ' or '  '
      return ('%s%s  (%s)'):format(mark, s.title or s.id, ago(s.last_activity))
    end,
  }, function(s)
    if s then
      (opts.on_choice or open_session)(s)
    end
  end)
end

--- Picks a subagent or background command of a session (default: the active terminal's)
--- and opens its transcript or output.
--- @param opts? claude-code.PickOpts|{ session_id?: string }
function M.subtasks(opts)
  opts = opts or {}
  local items = require('claude-code').subtasks(current_session(opts.session_id))
  vim.ui.select(items, {
    prompt = 'Claude subtask',
    kind = 'claude-code.subtask',
    format_item = function(t)
      return ('%s %-5s %s'):format(t.open and '*' or ' ', t.kind, t.description or t.id)
    end,
  }, function(t)
    if not t then
      return
    elseif opts.on_choice then
      opts.on_choice(t)
    elseif t.path then
      vim.cmd.edit({ t.path, magic = { file = false } })
    else
      vim.notify('claude-code: no output yet for ' .. t.id)
    end
  end)
end

--- Picks a file Claude read or edited in a session (default: the active terminal's) and
--- edits it.
--- @param opts? claude-code.PickOpts|{ session_id?: string }
function M.touched(opts)
  opts = opts or {}
  local items = require('claude-code').touched(current_session(opts.session_id))
  vim.ui.select(items, {
    prompt = 'File Claude touched',
    kind = 'claude-code.file',
    format_item = function(path)
      return vim.fn.fnamemodify(path, ':~:.')
    end,
  }, function(path)
    if not path then
      return
    elseif opts.on_choice then
      opts.on_choice(path)
    else
      vim.cmd.edit({ path, magic = { file = false } })
    end
  end)
end

return M
