if vim.g.loaded_bodgery then
  return
end
vim.g.loaded_bodgery = true

local group = vim.api.nvim_create_augroup('bodgery', {})

vim.api.nvim_create_autocmd('VimLeavePre', {
  group = group,
  desc = 'Stop the bodgery server and remove its lockfile',
  callback = function()
    if package.loaded.bodgery then
      require('bodgery').stop()
    end
  end,
})

-- Neovim 0.13+
if vim.fn.exists('##SessionWritePre') == 1 then
  vim.api.nvim_create_autocmd('SessionWritePre', {
    group = group,
    desc = 'Move agent terminal windows out of removed directories',
    callback = function()
      if package.loaded['bodgery.terminal'] then
        require('bodgery.restore').before_save()
      end
    end,
  })
end

vim.api.nvim_create_autocmd('SessionWritePost', {
  group = group,
  desc = 'Record agent terminals for session restore',
  callback = function()
    if package.loaded['bodgery.terminal'] then
      require('bodgery.restore').save()
    end
  end,
})

vim.api.nvim_create_autocmd('BufNew', {
  group = group,
  pattern = 'term://*',
  desc = 'Mark restored agent terminals for relaunch',
  callback = function(ev)
    require('bodgery.restore').on_new(ev)
  end,
})

vim.api.nvim_create_autocmd('BufReadCmd', {
  group = group,
  pattern = 'term://*',
  nested = true,
  desc = 'Relaunch a restored agent terminal',
  callback = function(ev)
    require('bodgery.restore').on_read(ev)
  end,
})

require('bodgery').detect()
