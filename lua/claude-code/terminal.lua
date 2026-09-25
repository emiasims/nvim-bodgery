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

return M
