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

--- Calls `fn` with `opts.session_id` and `config`, or the target terminal's session and
--- config.
--- @param opts { session_id?: string }
--- @param config? bodgery.ConfigArg
--- @param fn fun(session_id: string, config: bodgery.Config)
local function with_session(opts, config, fn)
  local get = require('bodgery.config').get
  if opts.session_id then
    if not config then
      error('bodgery: pass a config with a session_id', 0)
    end
    return fn(opts.session_id, get(config))
  end
  require('bodgery.terminal').target(nil, config and get(config), function(term)
    if not term then
      error('bodgery: no agent terminal to read a session from', 0)
    end
    fn(term.session_id or error('bodgery: the terminal has no session yet', 0), term.config)
  end)
end

--- @class bodgery.PickOpts
--- @field on_choice? fun(item: any) replaces the default action

--- Picks a session of `config`'s harness started in `opts.cwd` (default: the current
--- directory), leaving out archived ones. Choosing shows the terminal holding it, or
--- resumes it with |bodgery.resume()|.
--- @param config bodgery.ConfigArg
--- @param opts? bodgery.PickOpts|{ cwd?: string }
function M.sessions(config, opts)
  opts = opts or {}
  local cc = require('bodgery')
  local items = {}
  for s in cc.sessions(config, { cwd = opts.cwd or vim.fn.getcwd(), archived = false }) do
    items[#items + 1] = s
  end
  vim.ui.select(items, {
    prompt = 'Session',
    kind = 'bodgery.session',
    format_item = function(s)
      local mark = s.bufnr and '* ' or s.live and '+ ' or '  '
      return ('%s%s  (%s)'):format(mark, s.title or s.id, ago(s.last_activity))
    end,
  }, function(s)
    if not s then
      return
    elseif opts.on_choice then
      opts.on_choice(s)
    elseif s.bufnr and vim.api.nvim_buf_is_valid(s.bufnr) then
      vim.api.nvim_win_set_buf(0, s.bufnr)
    else
      cc.resume(s.id, nil, config)
    end
  end)
end

--- Picks a subagent or background command of `opts.session_id` (default: the target
--- terminal's session) and opens its transcript or output.
--- @param opts? bodgery.PickOpts|{ session_id?: string }
--- @param config? bodgery.ConfigArg required with `opts.session_id`
function M.subtasks(opts, config)
  opts = opts or {}
  with_session(opts, config, function(id, c)
    local items = require('bodgery').subtasks(id, c.name)
    vim.ui.select(items, {
      prompt = 'Subtask',
      kind = 'bodgery.subtask',
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
        vim.notify('bodgery: no output yet for ' .. t.id)
      end
    end)
  end)
end

--- Picks a file the agent read or edited in `opts.session_id` (default: the target
--- terminal's session) and edits it.
--- @param opts? bodgery.PickOpts|{ session_id?: string }
--- @param config? bodgery.ConfigArg required with `opts.session_id`
function M.touched(opts, config)
  opts = opts or {}
  with_session(opts, config, function(id, c)
    local items = require('bodgery').touched(id, c.name)
    vim.ui.select(items, {
      prompt = 'Touched file',
      kind = 'bodgery.file',
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
  end)
end

return M
