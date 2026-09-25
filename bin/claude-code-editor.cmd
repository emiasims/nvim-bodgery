@echo off
rem EDITOR for Claude terminals started by claude-code.nvim. Opens the file in that
rem Neovim and exits once its buffer is hidden.
setlocal
if "%~1"=="" exit /b 2
set "file=%~f1"
set "file=%file:\=\\%"
curl -sS --fail --noproxy * -o nul -X POST ^
  -H "Authorization: Bearer %CLAUDE_NVIM_TOKEN%" ^
  -H "Content-Type: application/json" ^
  --data-binary "{\"file\":\"%file%\"}" ^
  "http://127.0.0.1:%CLAUDE_CODE_SSE_PORT%/editor"
exit /b %errorlevel%
