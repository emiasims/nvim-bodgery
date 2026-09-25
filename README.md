# bodging.nvim

**[Bodge](https://en.wiktionary.org/wiki/bodge)** may refer to:
- [Bodging](https://en.wikipedia.org/wiki/Bodging), a traditional woodturning craft, especially in chair-making
- A British English slang term meaning a makeshift, clumsy, or temporary repair; see [Kludge](https://en.wikipedia.org/wiki/Kludge) or [Hack (computing)](https://en.wikipedia.org/wiki/Hack_(computing))

Whether bodging nvim ends up a craft or a hack is your job. I'm just here to give you some tools and get out of your way.

Configure a harness and command, open it with `:Claude`, `:Codex`, `:Pi`, etc, then ask it to configure it to your heart's desire. Cookbook (but not batteries) included! They are aware of your neovim the way they should be: your config, help docs, can see what you see, etc.

## KISS

Never fuck with windows, tabs, etc. 
Let the user decide if they want a 'toggle' and what toggling is attached to (a buffer? tab? project?)
Harness terminals should survive `:mksession` and loading them - a `ZR` should resume your open sessions.
Build your own UI the way you want - but with some useful recipes.
`<C-g>` or whatever you use for 'drop into my editor' should just use your current neovim session.
Standard tool/ide integration exists and can be hooked into.
Allow as many configurations as you want. Three different claude setups, Pi, and Codex? go for it.

Provide autocmds and lua interfaces for agent hooks.


An agent terminal is just a buffer. It goes wherever `:terminal` or `:split` would put it, and bodging leaves your windows and tabs alone unless you call it. When something has to open a window, like a diff for review, it splits the current window (vertically if it's wide), and you can hand it a function to do anything else.

You get mechanisms and a cookbook. Pickers go through `vim.ui.select`, so the picker you already use shows up. A floating prompt, a dedicated agent tab, and a statusline component are all recipes, and the agent can read the cookbook and adapt one for you.

The agent looks after its own integration. It knows where your config lives, can try a change in your running Neovim before writing it to disk, and keeps notes on your setup in a file in your config, where any harness in any project can find them.

## Setup

```lua
require('bodging').setup({ harness = 'claude', cmd = { 'claude', '--model', 'opus' } })
```

This defines `:Claude`, which takes modifiers the way `:split` does (`:vertical Claude`, `:tab Claude`). `:help bodging` covers the rest.

## Tools

The agent gets:

- your help docs, read by tag or searched, including every plugin's `doc/`
- your screen as you see it, with highlight groups if it asks
- diagnostics from `vim.diagnostic` and treesitter, before and after each edit
- diff review, where you can edit the proposal before `:w` accepts it
- Lua in your running Neovim, once you turn it on
- whatever tools you register, even mid-session

You get:

- sessions, subtasks, and touched files, with resume
- `User` events for sessions, tool calls, status, and subtasks
- hook callbacks in Lua, for example to deny a tool call
- agent terminals that survive `:mksession`
- the agent's `<C-g>` prompt editor, opened in this Neovim
