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
--- @field entered? number |vim.uv.hrtime()| of the last open or entry

--- @class bodging.Context
--- @field win integer
--- @field buf integer
--- @field tab integer

--- A builtin name from |bodging.config.resolvers|, or a function returning a terminal's
--- buffer.
--- @alias bodging.Resolver string|fun(ctx: bodging.Context, config?: bodging.Config): integer?

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

--- @param win? integer defaults to the current window
--- @return bodging.Context
function M.context(win)
  win = win or vim.api.nvim_get_current_win()
  return { win = win, buf = vim.api.nvim_win_get_buf(win), tab = vim.api.nvim_win_get_tabpage(win) }
end

--- Makes `term` the terminal of `ctx`'s window, buffer, and tab, and the last one used.
--- @param term bodging.Terminal
--- @param ctx bodging.Context
local function record(term, ctx)
  term.entered = vim.uv.hrtime()
  vim.w[ctx.win].bodging_term = term.bufnr
  if vim.api.nvim_buf_is_valid(ctx.buf) then
    vim.b[ctx.buf].bodging_term = term.bufnr
  end
  vim.t[ctx.tab].bodging_term = term.bufnr
  vim.g.bodging_term = term.bufnr
end

local group = vim.api.nvim_create_augroup('bodging.terminal', { clear = true })

--- @type integer? the window WinLeave left
local left
--- @type boolean the BufEnter that follows WinEnter belongs to the window switch
local switching = false

vim.api.nvim_create_autocmd('WinLeave', {
  group = group,
  callback = function()
    left = vim.api.nvim_get_current_win()
  end,
})

vim.api.nvim_create_autocmd('WinEnter', {
  group = group,
  desc = 'Record the window a terminal was entered from',
  callback = function()
    switching = true
    vim.schedule(function()
      switching = false
    end)
    local term = M.terminals[vim.api.nvim_get_current_buf()]
    if term and left and left ~= vim.api.nvim_get_current_win() and vim.api.nvim_win_is_valid(left) then
      record(term, M.context(left))
    end
  end,
})

vim.api.nvim_create_autocmd('BufEnter', {
  group = group,
  desc = 'Record the window and buffer a terminal replaced',
  callback = function(ev)
    local term = M.terminals[ev.buf]
    if not term or switching then
      return
    end
    local ctx = M.context()
    local alt = vim.fn.bufnr('#')
    ctx.buf = alt > 0 and alt or ctx.buf
    record(term, ctx)
  end,
})

--- @class bodging.OpenOpts
--- @field cwd? string
--- @field args? string[] appended to `config.cmd`
--- @field mods? vim.api.keyset.cmd_mods open in a split built by `:new` with these modifiers
--- @field win? integer start in this window, replacing its buffer
--- @field buf? boolean start in the current buffer, which must be empty, as a restored
---   session's terminal is

--- Starts an agent in a terminal. Without `mods` or `win` it takes the current window, as
--- `:terminal` does.
--- @param config bodging.Config
--- @param opts? bodging.OpenOpts
--- @return integer bufnr
function M.open(config, opts)
  opts = opts or {}
  local cc = require('bodging')
  local harness = cc.harnesses[config.harness]
  cc.start(config.harness)

  local token = vim.text.hexencode(assert(vim.uv.random(16)))
  local launch = harness.launch({ cmd = config.cmd, args = opts.args, token = token })

  local origin = M.context()
  local win = opts.win or origin.win
  if opts.mods then
    vim.api.nvim_cmd({ cmd = 'new', mods = opts.mods }, {})
    win = vim.api.nvim_get_current_win()
  elseif not opts.buf then
    vim.api.nvim_win_set_buf(win, vim.api.nvim_create_buf(true, false))
  end
  local bufnr = vim.api.nvim_win_get_buf(win)
  local cwd = opts.cwd or vim.fn.getcwd()
  local job = vim.api.nvim_win_call(win, function()
    return vim.fn.jobstart(launch.cmd, { term = true, cwd = cwd, env = launch.env })
  end)
  if job <= 0 then
    error(('bodging: failed to start %s'):format(launch.cmd[1]))
  end
  -- filetype detection never runs on terminal buffers
  vim.bo[bufnr].filetype = config.harness

  local term = { bufnr = bufnr, token = token, job = job, cwd = cwd, config = config, harness = harness }
  M.terminals[bufnr] = term
  by_token[token] = term
  record(term, origin)
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

--- @param term bodging.Terminal
--- @param text string
local function send(term, text)
  vim.fn.chansend(term.job, text)
  vim.defer_fn(function()
    if M.terminals[term.bufnr] == term then
      vim.fn.chansend(term.job, '\r')
    end
  end, M.submit_delay)
end

--- Types `text` into the terminal and submits it. A busy terminal is handled by
--- `config.on_busy`.
--- @param term bodging.Terminal
--- @param text string
function M.submit(term, text)
  -- typing into a permission prompt would answer it, so waiting counts as busy
  if term.status ~= 'busy' and term.status ~= 'waiting' then
    return send(term, text)
  end

  local actions = {
    interrupt = function()
      vim.fn.chansend(term.job, term.harness.interrupt)
      vim.defer_fn(function()
        send(term, text)
      end, M.submit_delay)
    end,
    queue = function()
      vim.api.nvim_create_autocmd('User', {
        group = group,
        pattern = 'ClaudeStatusChanged',
        callback = function(ev)
          if ev.data.bufnr == term.bufnr and ev.data.status == 'idle' then
            send(term, text)
            return true
          end
        end,
      })
    end,
  }

  local on_busy = term.config.on_busy
  if on_busy == 'error' then
    error(('bodging: %s is busy in buffer %d'):format(term.config.name, term.bufnr), 0)
  elseif on_busy == 'prompt' then
    vim.ui.select({ 'interrupt', 'queue' }, {
      prompt = term.config.name .. ' is busy',
      format_item = function(item)
        return item == 'interrupt' and 'Interrupt and send now' or 'Send when idle'
      end,
    }, function(choice)
      if choice then
        actions[choice]()
      end
    end)
  else
    actions[on_busy]()
  end
end

--- @param bufnr integer?
--- @return integer?
local function live(bufnr)
  return bufnr and M.terminals[bufnr] and bufnr
end

--- @type table<string, fun(ctx: bodging.Context, config?: bodging.Config): integer?>
M.resolvers = {
  window = function(ctx)
    return live(vim.w[ctx.win].bodging_term)
  end,
  buffer = function(ctx)
    return live(vim.b[ctx.buf].bodging_term)
  end,
  tab = function(ctx)
    return live(vim.t[ctx.tab].bodging_term)
  end,
  global = function()
    return live(vim.g.bodging_term)
  end,
  project = function(ctx, config)
    local markers = (config or require('bodging.config').defaults).root_markers
    -- real paths, since buffer names resolve symlinks such as macOS /var and cwds don't
    local function root(source, fallback)
      local dir = vim.fs.root(source, markers) or fallback
      return vim.uv.fs_realpath(dir) or dir
    end
    local want = root(ctx.buf, vim.fn.getcwd(ctx.win))
    local best
    for bufnr, term in pairs(M.terminals) do
      if
        root(term.cwd, term.cwd) == want
        and (not best or (term.entered or 0) > (M.terminals[best].entered or 0))
      then
        best = bufnr
      end
    end
    return best
  end,
}

--- @param terms bodging.Terminal[]
--- @param fn fun(term: bodging.Terminal)
local function pick(terms, fn)
  table.sort(terms, function(a, b)
    return a.bufnr < b.bufnr
  end)
  vim.ui.select(terms, {
    prompt = 'Agent terminal',
    kind = 'bodging.terminal',
    format_item = function(term)
      return ('%d %s %s'):format(term.bufnr, term.config.name, term.session_id or '')
    end,
  }, function(term)
    if term then
      fn(term)
    end
  end)
end

--- Calls `fn` with the terminal a call acts on: `bufnr`'s when given, else the current
--- window's, else the first match of `config.active` (the core default without `config`).
--- `fn` gets nil when the chain reaches `new`.
--- @param bufnr? integer
--- @param config? bodging.Config
--- @param fn fun(term?: bodging.Terminal)
function M.target(bufnr, config, fn)
  if bufnr then
    return fn(M.terminals[bufnr] or error(('bodging: buffer %d is not an agent terminal'):format(bufnr), 0))
  end
  local ctx = M.context()
  if M.terminals[ctx.buf] then
    return fn(M.terminals[ctx.buf])
  end
  for _, resolver in ipairs((config or require('bodging.config').defaults).active) do
    if resolver == 'new' then
      return fn(nil)
    elseif resolver == 'error' then
      break
    elseif resolver == 'pick' then
      local terms = vim.tbl_values(M.terminals)
      if #terms > 0 then
        return pick(terms, fn)
      end
    else
      local found = live((M.resolvers[resolver] or resolver)(ctx, config))
      if found then
        return fn(M.terminals[found])
      end
    end
  end
  error('bodging: no agent terminal found, pass a bufnr', 0)
end

--- The window showing `bufnr` in the current tab.
--- @param bufnr integer
--- @return integer?
function M.shown(bufnr)
  local tab = vim.api.nvim_get_current_tabpage()
  for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
    if vim.api.nvim_win_get_tabpage(win) == tab then
      return win
    end
  end
end

--- Closes `win`, or shows the alternate buffer in it when it is the tab's only window.
--- @param win integer
function M.hide(win)
  if #vim.api.nvim_tabpage_list_wins(vim.api.nvim_win_get_tabpage(win)) > 1 then
    vim.api.nvim_win_hide(win)
    return
  end
  vim.api.nvim_win_call(win, function()
    local alt = vim.fn.bufnr('#')
    if alt > 0 and alt ~= vim.api.nvim_get_current_buf() and vim.api.nvim_buf_is_valid(alt) then
      vim.cmd.buffer(alt)
    else
      vim.cmd.enew()
    end
  end)
end

--- Shows `term` in the window `config.show.window` picks and enters it, or starts a new
--- terminal there when `term` is nil.
--- @param term? bodging.Terminal
--- @param config? bodging.Config the terminal's own when omitted
function M.show(term, config)
  config = config or (term and term.config)
  if not config then
    error('bodging: pass a config to start a new terminal', 0)
  end
  local win = config.show.window(M.context(), term)
  if term then
    vim.api.nvim_win_set_buf(win, term.bufnr)
  else
    M.open(config, { win = win })
  end
  vim.api.nvim_set_current_win(win)
end

--- The most recently used terminal running `harness`.
--- @param harness string
--- @return bodging.Terminal?
function M.last(harness)
  local best
  for _, term in pairs(M.terminals) do
    if term.config.harness == harness and (not best or (term.entered or 0) > (best.entered or 0)) then
      best = term
    end
  end
  return best
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
