local M = {}

--- @type claude-code.Config?
M.config = nil

--- Stops the server and removes the lockfile. `setup()` starts them again.
function M.stop() end

--- Configures the plugin. Calling it again replaces the previous configuration.
--- @param opts? table see |claude-code.Config|
function M.setup(opts)
  -- validate first so a bad call leaves the running configuration intact
  local config = require('claude-code.config').resolve(opts)
  M.stop()
  M.config = config

  local group = vim.api.nvim_create_augroup('claude-code', { clear = true })
  vim.api.nvim_create_autocmd('VimLeavePre', { group = group, callback = M.stop })
end

return M
