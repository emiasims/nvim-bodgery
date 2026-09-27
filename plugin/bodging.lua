if vim.g.loaded_bodging then
  return
end
vim.g.loaded_bodging = true

local group = vim.api.nvim_create_augroup('bodging', {})

vim.api.nvim_create_autocmd('VimLeavePre', {
  group = group,
  desc = 'Stop the bodging server and remove its lockfile',
  callback = function()
    if package.loaded.bodging then
      require('bodging').stop()
    end
  end,
})

vim.api.nvim_create_autocmd('SessionWritePost', {
  group = group,
  desc = 'Record agent terminals for session restore',
  callback = function()
    if package.loaded['bodging.terminal'] then
      require('bodging.restore').save()
    end
  end,
})

vim.api.nvim_create_autocmd('BufNew', {
  group = group,
  pattern = 'term://*',
  desc = 'Mark restored agent terminals for relaunch',
  callback = function(ev)
    require('bodging.restore').on_new(ev)
  end,
})

vim.api.nvim_create_autocmd('BufReadCmd', {
  group = group,
  pattern = 'term://*',
  nested = true,
  desc = 'Relaunch a restored agent terminal',
  callback = function(ev)
    require('bodging.restore').on_read(ev)
  end,
})

require('bodging').detect()
