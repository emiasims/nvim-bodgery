local M = {}

--- @alias bodgery.BufferScope 'listed'|'unlisted'|'all'|'visible'|'tab'

--- @class bodgery.BufferWindow
--- @field winid integer
--- @field tab integer tab page number

--- @class bodgery.Buffer
--- @field bufnr integer
--- @field name string full path, or `[No Name]`, `[Scratch]`, `[Prompt]` as `:ls` shows them
--- @field current boolean shown in the current window
--- @field alternate boolean
--- @field listed boolean
--- @field loaded boolean
--- @field hidden boolean loaded and in no window
--- @field modified boolean
--- @field modifiable boolean
--- @field readonly boolean
--- @field job? 'running'|'finished'|'none' terminal buffers only
--- @field filetype string
--- @field buftype string
--- @field lines? integer loaded buffers only
--- @field line integer last cursor line
--- @field lastused integer seconds since the epoch, 0 if never
--- @field windows bodgery.BufferWindow[]

--- @param info vim.fn.getbufinfo.ret.item
--- @return string
local function name(info)
  if info.name ~= '' then
    return info.name
  end
  local buftype = vim.bo[info.bufnr].buftype
  return buftype == 'prompt' and '[Prompt]' or buftype == 'nofile' and '[Scratch]' or '[No Name]'
end

--- @param bufnr integer
--- @return 'running'|'finished'|'none'
local function job(bufnr)
  local chan = vim.bo[bufnr].channel
  if chan == 0 then
    return 'none'
  end
  return vim.fn.jobwait({ chan }, 0)[1] == -1 and 'running' or 'finished'
end

--- @param info vim.fn.getbufinfo.ret.item
--- @return bodgery.Buffer
local function entry(info)
  local bo = vim.bo[info.bufnr]
  local windows = vim.tbl_map(function(winid)
    return { winid = winid, tab = vim.api.nvim_tabpage_get_number(vim.api.nvim_win_get_tabpage(winid)) }
  end, info.windows)
  return {
    bufnr = info.bufnr,
    name = name(info),
    current = info.bufnr == vim.api.nvim_get_current_buf(),
    alternate = info.bufnr == vim.fn.bufnr('#'),
    listed = info.listed == 1,
    loaded = info.loaded == 1,
    hidden = info.hidden == 1,
    modified = info.changed == 1,
    modifiable = bo.modifiable,
    readonly = bo.readonly,
    job = bo.buftype == 'terminal' and job(info.bufnr) or nil,
    filetype = bo.filetype,
    buftype = bo.buftype,
    lines = info.loaded == 1 and info.linecount or nil,
    line = info.lnum,
    lastused = info.lastused,
    windows = windows,
  }
end

--- @type table<bodgery.BufferScope, fun(info: vim.fn.getbufinfo.ret.item): boolean>
local scopes = {
  listed = function(info)
    return info.listed == 1
  end,
  unlisted = function(info)
    return info.listed == 0
  end,
  all = function()
    return true
  end,
  visible = function(info)
    return #info.windows > 0
  end,
  tab = function(info)
    local tab = vim.api.nvim_get_current_tabpage()
    return vim.iter(info.windows):any(function(winid)
      return vim.api.nvim_win_get_tabpage(winid) == tab
    end)
  end,
}

--- @param scope bodgery.BufferScope
--- @return bodgery.Buffer[]
function M.list(scope)
  local keep = scopes[scope]
  if not keep then
    error(('unknown scope %q'):format(scope), 0)
  end
  local out = {}
  for _, info in ipairs(vim.fn.getbufinfo()) do
    if keep(info) then
      out[#out + 1] = entry(info)
    end
  end
  return out
end

--- @type bodgery.ToolSpec
M.tool = {
  description = "Lists the user's Neovim buffers, like `:ls`. `scope` picks which: listed "
    .. '(default, `:ls`), unlisted (`:ls u`), all (`:ls!`), visible (shown in a window on any '
    .. 'tab, listed or not), or tab (shown in a window on the current tab). Each entry has the '
    .. "buffer's full name, state flags (current, alternate, loaded, hidden, modified, readonly, "
    .. 'terminal job), filetype, line count, last cursor line, and the windows showing it.',
  input_schema = {
    type = 'object',
    properties = {
      scope = { type = 'string', enum = { 'listed', 'unlisted', 'all', 'visible', 'tab' } },
    },
  },
  handler = function(args)
    local bufs = M.list(args.scope or 'listed')
    return #bufs == 0 and 'no buffers' or bufs
  end,
}

return M
