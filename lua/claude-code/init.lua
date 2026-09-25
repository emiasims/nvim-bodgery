local M = {}

--- @type claude-code.Config?
M.config = nil

--- @type claude-code.http.Server?
M.server = nil

--- @type claude-code.http.Route[]
M.routes = {}

--- Stops the server and removes the lockfile. `setup()` starts them again.
function M.stop()
  if M.server then
    M.server:stop()
    M.server = nil
  end
end

--- Configures the plugin and starts the server. Calling it again replaces the previous
--- configuration and server.
--- @param opts? table see |claude-code.Config|
function M.setup(opts)
  -- validate first so a bad call leaves the running configuration intact
  local config = require('claude-code.config').resolve(opts)
  M.stop()
  M.config = config

  local group = vim.api.nvim_create_augroup('claude-code', { clear = true })
  vim.api.nvim_create_autocmd('VimLeavePre', { group = group, callback = M.stop })

  M.server = require('claude-code.server.http').start({
    routes = M.routes,
    auth = function() end,
  })
end

return M
