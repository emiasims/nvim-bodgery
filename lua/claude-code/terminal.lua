local M = {}

--- @class claude-code.Terminal
--- @field bufnr integer
--- @field token string
--- @field job integer
--- @field session_id? string
--- @field status? 'busy'|'idle'|'waiting'

--- @type table<integer, claude-code.Terminal>
M.terminals = {}

--- @type table<string, claude-code.Terminal>
local by_token = {}

--- @param token string
--- @return claude-code.Terminal?
function M.lookup(token)
  return by_token[token]
end

--- @param bufnr integer
local function unregister(bufnr)
  local term = M.terminals[bufnr]
  if term then
    M.terminals[bufnr] = nil
    by_token[term.token] = nil
  end
end

--- @class claude-code.OpenOpts
--- @field cwd? string
--- @field args? string[] appended to `opts.cmd`
--- @field mods? vim.api.keyset.cmd_mods open in a split built by `:new` with these modifiers

--- Starts Claude in a terminal. Without `mods` it takes the current window, as `:terminal`
--- does.
--- @param opts? claude-code.OpenOpts
--- @return integer bufnr
function M.open(opts)
  opts = opts or {}
  local cc = require('claude-code')
  assert(cc.server, 'claude-code: call setup() first')

  local token = vim.text.hexencode(assert(vim.uv.random(16)))
  local launch = cc.harness.launch({ cmd = cc.config.cmd, args = opts.args, token = token })

  if opts.mods then
    vim.api.nvim_cmd({ cmd = 'new', mods = opts.mods }, {})
  else
    vim.api.nvim_win_set_buf(0, vim.api.nvim_create_buf(true, false))
  end
  local bufnr = vim.api.nvim_get_current_buf()
  local job = vim.fn.jobstart(launch.cmd, { term = true, cwd = opts.cwd, env = launch.env })
  if job <= 0 then
    error(('claude-code: failed to start %s'):format(launch.cmd[1]))
  end

  local term = { bufnr = bufnr, token = token, job = job }
  M.terminals[bufnr] = term
  by_token[token] = term
  vim.api.nvim_create_autocmd('BufWipeout', {
    buffer = bufnr,
    once = true,
    callback = function()
      unregister(bufnr)
    end,
  })
  return bufnr
end

--- A window in the current tab for showing a file beside Claude. With a Claude window in
--- the tab, this is the only other window, the one nearest Claude in `winlayout()` when
--- there are several, or a new vertical split when Claude is alone. Without one, it is the
--- current window.
--- @return integer winid
function M.pick_window()
  local cur = vim.api.nvim_get_current_win()
  local paths, order = {}, {}
  local function walk(node, path)
    if node[1] == 'leaf' then
      order[#order + 1] = node[2]
      paths[node[2]] = path
      return
    end
    for i, child in ipairs(node[2]) do
      walk(child, vim.list_extend(vim.list_slice(path), { i }))
    end
  end
  walk(vim.fn.winlayout(), {})

  local claude, others = nil, {}
  for _, win in ipairs(order) do
    if M.terminals[vim.api.nvim_win_get_buf(win)] then
      if not claude or win == cur then
        claude = win
      end
    else
      others[#others + 1] = win
    end
  end
  if not claude then
    return cur
  elseif #others == 0 then
    return vim.api.nvim_open_win(vim.api.nvim_win_get_buf(claude), false, { vertical = true, win = claude })
  end

  local function distance(a, b)
    local common = 0
    while a[common + 1] and a[common + 1] == b[common + 1] do
      common = common + 1
    end
    return #a + #b - 2 * common
  end
  local best, best_d
  for _, win in ipairs(others) do
    local d = distance(paths[win], paths[claude])
    if not best_d or d < best_d then
      best, best_d = win, d
    end
  end
  return best
end

return M
