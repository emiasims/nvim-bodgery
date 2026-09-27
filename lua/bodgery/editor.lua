local M = {}

--- Opens `file` through `open` and calls `done` once its buffer is hidden or deleted.
--- Returns a function that stops waiting.
--- @param file string
--- @param open fun(file: string)
--- @param done fun()
--- @return fun() cancel
function M.edit(file, open, done)
  vim.filetype.add({ filename = { [file] = 'markdown.prompt' } })
  open(file)
  local bufnr = vim.fn.bufnr(file)
  local group = vim.api.nvim_create_augroup('bodgery.editor.' .. bufnr, { clear = true })
  local function finish()
    pcall(vim.api.nvim_del_augroup_by_id, group)
    done()
    -- deferred, since the buffer is still being hidden
    vim.schedule(function()
      local unused = vim.api.nvim_buf_is_valid(bufnr)
        and #vim.fn.win_findbuf(bufnr) == 0
        and not vim.bo[bufnr].modified
      if unused then
        vim.api.nvim_buf_delete(bufnr, {})
      end
    end)
  end
  if bufnr == -1 or #vim.fn.win_findbuf(bufnr) == 0 then
    finish()
  else
    vim.api.nvim_create_autocmd({ 'BufHidden', 'BufDelete', 'BufWipeout' }, {
      group = group,
      buffer = bufnr,
      once = true,
      callback = finish,
    })
  end
  return function()
    pcall(vim.api.nvim_del_augroup_by_id, group)
  end
end

--- Serves `POST /editor` with `{ "file": path }`, replying once the user is done.
--- @param server bodgery.http.Server
function M.register(server)
  server:route({
    method = 'POST',
    path = '/editor',
    handler = function(req, respond)
      local ok, body = pcall(vim.json.decode, req.body)
      local file = ok and type(body) == 'table' and body.file
      if type(file) ~= 'string' or file == '' then
        return 400, { error = 'expected {"file": path}' }
      end
      local finished = false
      --- @type bodgery.Terminal
      local term = req.ctx
      local cancel = M.edit(file, term.config.editor.open, function()
        finished = true
        req.conn.on_close = nil
        respond(200, vim.empty_dict())
      end)
      if not finished then
        req.conn.on_close = cancel
      end
    end,
  })
end

return M
