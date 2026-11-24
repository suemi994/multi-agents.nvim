# AGENTS.md

## Project Overview

`multi-agents.nvim` is a Lua plugin for Neovim 0.11+. It runs agent CLIs or shell commands in floating windows and vertical splits. Each terminal job stays alive while its window is hidden, and users can select, reopen, or reshape sessions independently.

## Development Commands

Run these from the repository root.

| Task | Command |
| --- | --- |
| Test multi-agent commands and terminal behavior without Plenary | `nvim --headless -u NONE --cmd 'set rtp+=.' -l tests/multi_agents.lua` |
| Run the Plenary suite used by CI | `make test` or `./scripts/test.sh` |
| Run the older Vimscript smoke tests | `make test-legacy` |
| Lint plugin Lua with LuaCheck | `make lint` |
| Check formatting | `stylua --check lua/` |
| Format plugin Lua | `make format` |
| Generate or remove optional LDoc output | `make docs` or `make clean` |

The Plenary runner uses Neovim and GNU `timeout`. If needed, it clones `plenary.nvim` into `~/.local/share/nvim/site/pack/vendor/start/plenary.nvim`. GitHub Actions runs that suite on stable and nightly Neovim. Run the standalone multi-agent test separately.

## Repository Layout

- `lua/multi-agents/init.lua` is the public entry point. `agents.lua` owns commands, session selection, and terminal lifecycle. `resize.lua` handles mouse resizing.
- `lua/claude-code/` provides compatibility and shared configuration, Git-root lookup, and terminal helpers. Check callers in both namespaces when changing shared helpers.
- `tests/multi_agents.lua` exercises the active command interface. `tests/spec/`, `tests/run_tests.lua`, and `tests/minimal-init.lua` support the Plenary suite. `test/` contains the older Vimscript tests.
- `README.md` covers installation and usage. `doc/multi-agents.txt` is the source for Neovim help.

## Coding Conventions

- Follow `stylua.toml` for two-space indentation, a 100-column target, Unix line endings, and a preference for single quotes.
- Use local helpers and `snake_case` for Lua functions and variables. LuaCheck uses `.luacheckrc`, which recognizes `vim` and sets a 120-column lint limit.

## Project Rules

- Preserve the terminal buffer and job when toggling or reshaping an agent. Closing an agent stops the job. Agent exit removes its buffer.
- `git.use_git_root` controls an agent's launch directory. Multiple live sessions can share a repository root.
- Update both `README.md` and `doc/multi-agents.txt` when changing commands, options, or defaults. Edit the help source directly. `doc/tags` and `doc/luadoc/` are generated.

## Git Workflow

- `CONTRIBUTING.md` asks contributors to work on a branch, test changes, submit a PR with a clear description, and open an issue first for significant changes. CI runs on pushes and PRs targeting `main`.
- `./scripts/setup-hooks.sh` sets `core.hooksPath` to `.githooks`. When Lua files are staged, the pre-commit hook runs `scripts/test.sh` from the repository root.
- Releases use semantic version tags such as `v0.4.3`. The release workflow also supports manual dispatch and uses the matching `CHANGELOG.md` section for a tagged release when available.

## Common Tasks

- To try the checkout interactively, run `nvim --clean --cmd 'set rtp+=.'`, then enter `:lua require('multi-agents').setup({})`. Use `:OpenAgent --mode float sh -i` to start a shell without installing an agent CLI.
- For terminal layout changes, use `:ToggleAgent` and `:ReshapeAgent` on the same session and add regression assertions in `tests/multi_agents.lua`.
