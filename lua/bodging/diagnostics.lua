local M = {}

--- @class bodging.Diagnostic
--- @field lnum integer 0-based
--- @field col integer 0-based
--- @field end_lnum integer
--- @field end_col integer
--- @field severity vim.diagnostic.Severity
--- @field message string
--- @field source? string
--- @field code? string|integer

--- Treesitter `ERROR` and `MISSING` nodes in every tree of the buffer's parser.
--- @param bufnr integer
--- @return bodging.Diagnostic[]
local function syntax_errors(bufnr)
  local ok, parser = pcall(vim.treesitter.get_parser, bufnr, nil, { error = false })
  if not ok or not parser then
    return {}
  end
  parser:parse(true)

  local out = {}
  local function add(node, message)
    local sr, sc, er, ec = node:range()
    out[#out + 1] = {
      lnum = sr,
      col = sc,
      end_lnum = er,
      end_col = ec,
      severity = vim.diagnostic.severity.ERROR,
      message = message,
      source = 'treesitter',
    }
  end
  local function walk(node)
    if node:missing() then
      return add(node, ('Missing %s'):format(node:type()))
    elseif node:type() == 'ERROR' then
      return add(node, 'Syntax error')
    end
    for child in node:iter_children() do
      if child:has_error() or child:missing() then
        walk(child)
      end
    end
  end
  parser:for_each_tree(function(tree)
    local root = tree:root()
    if root:has_error() then
      walk(root)
    end
  end)
  return out
end

--- @param bufnr integer
local function is_file(bufnr)
  return vim.api.nvim_buf_is_loaded(bufnr)
    and vim.bo[bufnr].buftype == ''
    and vim.api.nvim_buf_get_name(bufnr) ~= ''
end

--- Diagnostics from every `vim.diagnostic` source plus treesitter syntax errors, for one
--- buffer or every loaded file buffer.
--- @param bufnr? integer
--- @return { bufnr: integer, path: string, diagnostics: bodging.Diagnostic[] }[]
function M.collect(bufnr)
  local bufs = bufnr and { bufnr } or vim.tbl_filter(is_file, vim.api.nvim_list_bufs())
  local out = {}
  for _, b in ipairs(bufs) do
    if is_file(b) then
      local items = {}
      for _, d in ipairs(vim.diagnostic.get(b)) do
        items[#items + 1] = {
          lnum = d.lnum,
          col = d.col,
          end_lnum = d.end_lnum or d.lnum,
          end_col = d.end_col or d.col,
          severity = d.severity,
          message = d.message,
          source = d.source,
          code = d.code,
        }
      end
      vim.list_extend(items, syntax_errors(b))
      out[#out + 1] = { bufnr = b, path = vim.api.nvim_buf_get_name(b), diagnostics = items }
    end
  end
  return out
end

--- The loaded buffer for `path`, if any.
--- @param path string
--- @return integer?
function M.loaded_buffer(path)
  -- compare real paths, since buffer names resolve symlinks such as macOS /var
  local function real(p)
    return vim.uv.fs_realpath(p) or vim.fs.normalize(vim.fn.fnamemodify(p, ':p'))
  end
  local target = real(path)
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if is_file(b) and real(vim.api.nvim_buf_get_name(b)) == target then
      return b
    end
  end
end

return M
