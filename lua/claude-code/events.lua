local M = {}

--- Fires `User <name>` with `data`, which always carries `session_id` and `bufnr`.
--- @param name string
--- @param data table
function M.fire(name, data)
  vim.api.nvim_exec_autocmds('User', { pattern = name, data = data, modeline = false })
end

return M
