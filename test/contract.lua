-- Checks that every literal in DECISIONS.md's Sources list appears in the installed
-- Claude binary.
--
--   make contract [CLAUDE_BIN=path]
--
-- Literals marked "(minified name" are skipped, since they change per build.
local root = vim.fs.dirname(vim.fs.dirname(vim.fs.abspath(arg[0])))

local bin = vim.env.CLAUDE_BIN
if not bin or bin == '' then
  local exe = vim.fn.exepath('claude')
  bin = exe ~= '' and vim.uv.fs_realpath(exe) or nil
end
if not bin then
  io.stderr:write('claude not found on PATH, set CLAUDE_BIN\n')
  os.exit(2)
end

local literals, in_sources, in_list = {}, false, false
for line in io.lines(root .. '/DECISIONS.md') do
  if line:match('^## ') then
    in_sources = line == '## Sources'
  elseif in_sources and line:match('^%- ') then
    in_list = true
    for lit, pos in line:gmatch('`([^`]+)`()') do
      if not vim.startswith(line:sub(pos), ' (minified') then
        table.insert(literals, lit)
      end
    end
  elseif in_list and line ~= '' then
    break
  end
end

local res = vim.system({ 'strings', '-n', '6', bin }):wait()
if res.code ~= 0 then
  io.stderr:write(res.stderr)
  os.exit(2)
end

local missing = 0
for _, lit in ipairs(literals) do
  if not res.stdout:find(lit, 1, true) then
    io.write('missing: ', lit, '\n')
    missing = missing + 1
  end
end
io.write(('%s: %d of %d literals found\n'):format(bin, #literals - missing, #literals))
os.exit(missing == 0 and 0 or 1)
