local M = {}

--- Results returned by search and grep before the rest are counted and dropped.
M.max_results = 50

--- Lines returned by `nvim_help` before the section is cut.
M.max_lines = 300

--- @class claude-code.HelpTag
--- @field name string
--- @field file string absolute path of the help file

--- Tags from every `doc/tags` on 'runtimepath', first occurrence winning, as `:help` does.
--- @return claude-code.HelpTag[]
local function tags()
  local out, seen = {}, {}
  for _, tagfile in ipairs(vim.api.nvim_get_runtime_file('doc/tags', true)) do
    local dir = vim.fs.dirname(tagfile)
    for line in io.lines(tagfile) do
      local name, file = line:match('^([^\t]+)\t([^\t]+)\t')
      if name and not seen[name] and not name:find('^!_TAG_') then
        seen[name] = true
        out[#out + 1] = { name = name, file = vim.fs.joinpath(dir, file) }
      end
    end
  end
  return out
end

--- @param line string
--- @return boolean
local function defines_tag(line)
  return line:find('%*[^%s%*|]+%*') ~= nil
end

--- @param pattern string
--- @return vim.regex
local function regex(pattern)
  local ok, re = pcall(vim.regex, pattern)
  if not ok then
    error('invalid pattern: ' .. pattern, 0)
  end
  return re
end

--- @param lines string[]
--- @param total integer matches found, which can exceed `#lines`
--- @return string
local function capped(lines, total)
  if total > #lines then
    lines[#lines + 1] = ('(%d more not shown)'):format(total - #lines)
  end
  return table.concat(lines, '\n')
end

--- The help text from `tag` to the next tag definition.
--- @param tag string
--- @return string
function M.help(tag)
  local all = tags()
  local found
  for _, t in ipairs(all) do
    if t.name == tag then
      found = t
      break
    end
  end
  if not found then
    local names = vim.tbl_map(function(t)
      return t.name
    end, all)
    local close = vim.fn.matchfuzzy(names, tag, { limit = 5 })
    error(('no help tag %q. Closest: %s'):format(tag, table.concat(close, ', ')), 0)
  end

  local lines = vim.fn.readfile(found.file)
  local start
  for i, line in ipairs(lines) do
    if line:find('*' .. tag .. '*', 1, true) then
      start = i
      break
    end
  end
  if not start then
    error(('help tag %q is missing from %s'):format(tag, found.file), 0)
  end

  -- tags stacked on the lines under this one name the same section
  local stop = start + 1
  while stop <= #lines and defines_tag(lines[stop]) do
    stop = stop + 1
  end
  while stop <= #lines and not defines_tag(lines[stop]) do
    stop = stop + 1
  end
  -- a separator or blank line before the next tag belongs to the next section
  while stop - 1 > start and (lines[stop - 1]:find('^%s*$') or lines[stop - 1]:find('^[=-]+$')) do
    stop = stop - 1
  end

  local section = vim.list_slice(lines, start, math.min(stop - 1, start + M.max_lines - 1))
  if stop - start > M.max_lines then
    section[#section + 1] = ('(cut at %d lines, %s:%d)'):format(M.max_lines, found.file, start)
  end
  return table.concat(section, '\n')
end

--- Tag names matching a Vim regex, with their help file.
--- @param pattern string
--- @return string
function M.search(pattern)
  local re = regex(pattern)
  local out, total = {}, 0
  for _, t in ipairs(tags()) do
    if re:match_str(t.name) then
      total = total + 1
      if total <= M.max_results then
        out[#out + 1] = ('%s  (%s)'):format(t.name, vim.fs.basename(t.file))
      end
    end
  end
  return total == 0 and 'no matching tags' or capped(out, total)
end

--- Help lines matching a Vim regex, each with its file, line, and the tag before it.
--- Scans the files itself, since `:helpgrep` replaces the quickfix list.
--- @param pattern string
--- @return string
function M.grep(pattern)
  local re = regex(pattern)
  local out, total = {}, 0
  for _, file in ipairs(vim.api.nvim_get_runtime_file('doc/*.txt', true)) do
    local tag
    local lnum = 0
    for line in io.lines(file) do
      lnum = lnum + 1
      tag = line:match('%*([^%s%*|]+)%*') or tag
      if re:match_str(line) then
        total = total + 1
        if total <= M.max_results then
          out[#out + 1] = ('%s:%d [%s] %s'):format(vim.fs.basename(file), lnum, tag or '', vim.trim(line))
        end
      end
    end
  end
  return total == 0 and 'no matches' or capped(out, total)
end

--- @param key string
--- @param description string
--- @param fn fun(arg: string): string
--- @return claude-code.ToolSpec
local function spec(key, description, fn)
  return {
    description = description,
    input_schema = {
      type = 'object',
      properties = { [key] = { type = 'string' } },
      required = { key },
    },
    handler = function(args)
      return fn(args[key])
    end,
  }
end

--- @type table<string, claude-code.ToolSpec>
M.tools = {
  nvim_help = spec(
    'tag',
    "Returns the section of Neovim's help (runtime and installed plugins) under a help tag, "
      .. "as `:help` would show it. Tags look like 'nvim_buf_get_lines()', ':split', "
      .. "'vim.lsp.buf.hover()', or 'plugin-name-config'. Find tags with nvim_help_search.",
    M.help
  ),
  nvim_help_search = spec(
    'pattern',
    'Lists help tag names matching a Vim regex (\\c for case-insensitive), with their help file.',
    M.search
  ),
  nvim_helpgrep = spec(
    'pattern',
    'Searches the full text of every help file for a Vim regex. Each match shows the file, '
      .. 'line, and nearest tag above it, which nvim_help can open.',
    M.grep
  ),
}

return M
