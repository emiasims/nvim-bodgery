local M = {}

--- @class bodging.Terminal
--- @field bufnr integer
--- @field token string
--- @field job integer
--- @field cwd string
--- @field config bodging.Config
--- @field harness table the module `config.harness` names
--- @field session_id? string
--- @field status? 'busy'|'idle'|'waiting'

--- @type table<integer, bodging.Terminal>
M.terminals = {}

--- @type table<string, bodging.Terminal>
local by_token = {}

--- @param token string
--- @return bodging.Terminal?
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

--- @class bodging.OpenOpts
--- @field config? string config name, defaults to |bodging.default|
--- @field cwd? string
--- @field args? string[] appended to `opts.cmd`
--- @field mods? vim.api.keyset.cmd_mods open in a split built by `:new` with these modifiers
--- @field buf? boolean start in the current buffer, which must be empty, as a restored
---   session's terminal is

--- Starts Claude in a terminal. Without `mods` it takes the current window, as `:terminal`
--- does.
--- @param opts? bodging.OpenOpts
--- @return integer bufnr
function M.open(opts)
  opts = opts or {}
  local cc = require('bodging')
  -- resolve first so a bad option fails before anything listens
  local config = cc.configs[opts.config or cc.default]
  local harness = cc.harnesses[config.harness]
  cc.start(config.harness)

  local token = vim.text.hexencode(assert(vim.uv.random(16)))
  local launch = harness.launch({ cmd = config.cmd, args = opts.args, token = token })

  if opts.mods then
    vim.api.nvim_cmd({ cmd = 'new', mods = opts.mods }, {})
  elseif not opts.buf then
    vim.api.nvim_win_set_buf(0, vim.api.nvim_create_buf(true, false))
  end
  local bufnr = vim.api.nvim_get_current_buf()
  local cwd = opts.cwd or vim.fn.getcwd()
  local job = vim.fn.jobstart(launch.cmd, { term = true, cwd = cwd, env = launch.env })
  if job <= 0 then
    error(('bodging: failed to start %s'):format(launch.cmd[1]))
  end
  -- filetype detection never runs on terminal buffers
  vim.bo[bufnr].filetype = config.harness

  local term = { bufnr = bufnr, token = token, job = job, cwd = cwd, config = config, harness = harness }
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

--- Milliseconds between typed text and the Enter that submits it. Claude's input reads
--- text and Enter arriving together as a paste, where Enter adds a newline.
M.submit_delay = 100

--- Types `text` into the terminal and submits it.
--- @param term bodging.Terminal
--- @param text string
function M.submit(term, text)
  vim.fn.chansend(term.job, text)
  vim.defer_fn(function()
    if M.terminals[term.bufnr] == term then
      vim.fn.chansend(term.job, '\r')
    end
  end, M.submit_delay)
end

--- The terminal a call without an explicit target acts on: `bufnr` when given, else the
--- one Claude terminal shown in the current tab, else `opts.resolve()`.
--- @param bufnr? integer
--- @return bodging.Terminal
function M.active(bufnr)
  if bufnr then
    return M.terminals[bufnr] or error(('bodging: buffer %d is not a Claude terminal'):format(bufnr), 0)
  end
  local shown = {}
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local term = M.terminals[vim.api.nvim_win_get_buf(win)]
    if term and not vim.list_contains(shown, term) then
      shown[#shown + 1] = term
    end
  end
  if #shown == 1 then
    return shown[1]
  end
  local cc = require('bodging')
  local resolve = cc.configs[cc.default].resolve
  local resolved = resolve and resolve()
  if resolved and M.terminals[resolved] then
    return M.terminals[resolved]
  end
  error(
    ('bodging: %s Claude terminals shown, pass a bufnr or set opts.resolve'):format(
      #shown == 0 and 'no' or #shown
    ),
    0
  )
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
