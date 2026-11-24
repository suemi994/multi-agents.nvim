-- Run with: nvim --headless -u NONE --cmd 'set rtp+=.' -l tests/multi_agents.lua
local api = vim.api
local agents = require('multi-agents')

local function eq(expected, actual)
  assert(
    vim.deep_equal(expected, actual),
    ('Expected %s, got %s'):format(vim.inspect(expected), vim.inspect(actual))
  )
end

local function keys(input)
  api.nvim_feedkeys(api.nvim_replace_termcodes(input, true, false, true), 'xt', false)
end

local function visible(buf)
  return #vim.fn.win_findbuf(buf) > 0
end

local function live(buf)
  return vim.fn.jobwait({ vim.b[buf].terminal_job_id }, 0)[1] == -1
end

local function split_side()
  eq('', api.nvim_win_get_config(0).relative)
  local windows = vim.fn.winlayout()
  eq('row', windows[1])
  return windows[2][1][2] == api.nvim_get_current_win() and 'left' or 'right'
end

local function run()
  eq(vim.o.shell, require('claude-code.config').parse_config().command)
  local legacy = require('claude-code')
  legacy.setup({
    command = 'cat',
    command_variants = { custom = '--custom' },
    keymaps = { toggle = { variants = { custom = '<F8>' } } },
    refresh = { enable = false },
  })
  eq({}, vim.fn.getcompletion('ClaudeCode', 'command'))
  for _, mode in ipairs({ 'n', 't' }) do
    eq('<Cmd>ToggleAgent<CR>', vim.fn.maparg('<C-,>', mode))
  end
  eq('', vim.fn.maparg('<leader>cC', 'n'))
  eq('', vim.fn.maparg('<leader>cV', 'n'))
  eq(nil, legacy.config.command_variants.continue)
  eq(nil, legacy.config.command_variants.verbose)
  local variant_called
  legacy.toggle_with_variant = function(name)
    variant_called = name
  end
  vim.fn.maparg('<F8>', 'n', false, true).callback()
  eq('custom', variant_called)

  local editor = api.nvim_get_current_buf()
  vim.env.MULTI_AGENTS_INHERITED = 'inherited'
  local env_value = [[contains spaces ' " $ `]]
  agents.setup({
    command = 'cat',
    env = { MULTI_AGENTS_VALUE = env_value },
    window = {
      mode = 'vertical',
      vertical = { side = 'left', split_ratio = 0.4 },
      float = { width = 32, height = 8, row = 2, col = 3, border = 'single' },
      enter_insert = false,
    },
    git = { use_git_root = false },
  })

  local before_open = os.time()
  keys('<C-,>')
  local one = api.nvim_get_current_buf()
  eq('cat', vim.fn.fnamemodify(api.nvim_buf_get_name(one), ':t'))
  eq('terminal', vim.bo[one].buftype)
  eq(false, vim.bo[one].buflisted)
  eq('left', split_side())
  eq(math.floor(vim.o.columns * 0.4), api.nvim_win_get_width(0))
  keys('i<C-,>')
  assert(not visible(one) and live(one))
  keys('<C-,>')
  eq(one, api.nvim_get_current_buf())

  vim.cmd('OpenAgent --mode float cat -u')
  local after_open = os.time()
  local two = api.nvim_get_current_buf()
  eq('cat-2', vim.fn.fnamemodify(api.nvim_buf_get_name(two), ':t'))
  eq('editor', api.nvim_win_get_config(0).relative)
  eq(32, api.nvim_win_get_width(0))
  eq(8, api.nvim_win_get_height(0))
  assert(vim.wo.winhighlight:find('Normal:Normal', 1, true))
  assert(not visible(one) and live(one) and live(two) and not vim.bo[two].buflisted)

  local agent_float = api.nvim_win_get_config(0)
  vim.cmd.ListAgent()
  local list_float = api.nvim_win_get_config(0)
  for _, field in ipairs({ 'relative', 'row', 'col', 'border' }) do
    eq(agent_float[field], list_float[field])
  end
  eq(math.floor(vim.o.columns * 0.7), list_float.width)
  eq(math.floor((vim.o.lines - vim.o.cmdheight - 1) * 0.5), list_float.height)
  eq(0, vim.wo.winblend)
  assert(vim.wo.winhighlight:find('NormalFloat:Normal', 1, true))
  eq(true, vim.wo.cursorline)
  eq(false, vim.wo.wrap)

  local rows = api.nvim_buf_get_lines(0, 0, -1, false)
  local function check_row(row, label, buf)
    local pid = vim.fn.jobpid(vim.b[buf].terminal_job_id)
    local prefix = label .. '  PID ' .. pid .. '  '
    assert(vim.startswith(row, prefix), row)
    local time = row:sub(#prefix + 1)
    local format = '%Y-%m-%d %H:%M:%S'
    assert(time >= os.date(format, before_open) and time <= os.date(format, after_open), row)
  end
  eq(2, #rows)
  check_row(rows[1], '  [cat] cat  [vertical]', one)
  check_row(rows[2], '* [cat-2] cat -u  [float]', two)
  eq(2, api.nvim_win_get_cursor(0)[1])
  keys('<Up>')
  eq(1, api.nvim_win_get_cursor(0)[1])
  keys('<Down>')
  eq(2, api.nvim_win_get_cursor(0)[1])
  keys('<Up><CR>')
  vim.cmd.ListAgent()
  eq(1, api.nvim_win_get_cursor(0)[1])
  check_row(api.nvim_get_current_line(), '* [cat] cat  [vertical]', one)
  keys('<Esc>')
  vim.cmd.ToggleAgent()
  eq(one, api.nvim_get_current_buf())
  assert(not visible(two) and live(two))
  vim.cmd.ToggleAgent()
  assert(not visible(one) and live(one))
  eq(editor, api.nvim_get_current_buf())

  eq({ 'cat', 'cat-2' }, vim.fn.getcompletion('ToggleAgent ca', 'cmdline'))
  vim.cmd('ToggleAgent cat-2')
  eq(two, api.nvim_get_current_buf())
  eq('editor', api.nvim_win_get_config(0).relative)
  assert(vim.wo.winhighlight:find('Normal:Normal', 1, true))
  vim.cmd(
    'OpenAgent --mode vertical sh -c \'printf "%s\\n" "$MULTI_AGENTS_VALUE" "$MULTI_AGENTS_INHERITED" "$1"; exec cat\' sh --continue'
  )
  local three = api.nvim_get_current_buf()
  assert(
    vim.wait(2000, function()
      local lines = api.nvim_buf_get_lines(three, 0, 3, false)
      return vim.deep_equal(lines, { env_value, 'inherited', '--continue' })
    end),
    vim.inspect(api.nvim_buf_get_lines(three, 0, 3, false))
  )
  eq(nil, vim.env.MULTI_AGENTS_VALUE)

  for _, input in ipairs({
    'OpenAgent --mode grid',
    'OpenAgent --mode',
    'OpenAgent --unknown opt cat',
    'ToggleAgent absent',
  }) do
    assert(not pcall(vim.cmd, input), input)
    eq(three, api.nvim_get_current_buf())
  end

  vim.cmd('ToggleAgent ' .. two)
  eq(two, api.nvim_get_current_buf())
  local closed_job = vim.b[two].terminal_job_id
  vim.cmd.CloseAgent()
  assert(not api.nvim_buf_is_valid(two))
  assert(vim.fn.jobwait({ closed_job }, 2000)[1] ~= -1)
  vim.cmd.ToggleAgent()
  eq(three, api.nvim_get_current_buf())
  vim.cmd('CloseAgent ' .. three)
  vim.cmd.ToggleAgent()
  eq(one, api.nvim_get_current_buf())

  local exited = agents.open('true')
  assert(vim.wait(2000, function()
    return not api.nvim_buf_is_valid(exited)
  end))
  vim.cmd.ToggleAgent()
  eq(one, api.nvim_get_current_buf())
  api.nvim_buf_delete(one, { force = true })
  vim.cmd.ToggleAgent()
  local recreated = api.nvim_get_current_buf()
  assert(recreated ~= one and live(recreated))
  local replacement = agents.open('cat')
  assert(not visible(recreated) and visible(replacement) and live(recreated))
  eq(math.floor(vim.o.columns * 0.4), api.nvim_win_get_width(0))
  vim.cmd.CloseAgent()
  vim.cmd.CloseAgent()
  eq({}, vim.fn.getcompletion('CloseAgent ca', 'cmdline'))

  agents.setup({ command = 'cat', window = { mode = 'float' }, git = { use_git_root = false } })
  vim.cmd('OpenAgent --')
  eq('editor', api.nvim_win_get_config(0).relative)
  vim.cmd.CloseAgent()
  vim.cmd('OpenAgent --mode vertical')
  eq('right', split_side())
  vim.cmd.CloseAgent()

  vim.cmd.OpenVertical()
  eq('right', split_side())
  eq('cat', vim.fn.fnamemodify(api.nvim_buf_get_name(0), ':t'))
  vim.cmd('OpenFloat --mode vertical cat -u')
  eq('editor', api.nvim_win_get_config(0).relative)
  vim.cmd.ListAgent()
  assert(vim.startswith(api.nvim_get_current_line(), '* [cat-2] cat -u  [float]'))
  keys('<Esc>')
  vim.cmd.CloseAgent()
  vim.cmd.CloseAgent()

  for _, name in ipairs({ 'codex', 'claude', 'pi', 'agy', 'dsh' }) do
    local command = ([[sh -c 'exec cat' "/some/path/%s"]]):format(name)
    local first = agents.open(command)
    local second = agents.open(command)
    eq(name, vim.fn.fnamemodify(api.nvim_buf_get_name(first), ':t'))
    eq(name .. '-2', vim.fn.fnamemodify(api.nvim_buf_get_name(second), ':t'))
    vim.cmd.CloseAgent()
    vim.cmd.CloseAgent()
  end
  local long = "sh -c 'exec cat' pilot codex-helper " .. string.rep('长', vim.o.columns)
  local fallback = agents.open(long)
  eq('sh', vim.fn.fnamemodify(api.nvim_buf_get_name(fallback), ':t'))
  vim.cmd.ListAgent()
  eq(1, api.nvim_buf_line_count(0))
  assert(vim.startswith(api.nvim_get_current_line(), '* [sh] ' .. long .. '  [float]'))
  keys('zL')
  assert(vim.fn.winsaveview().leftcol > 0)
  keys('<Esc>')
  vim.cmd.CloseAgent()

  agents.setup({ keymaps = { toggle = { normal = '<F9>', terminal = false } } })
  eq('', vim.fn.maparg('<C-,>', 'n'))
  eq('', vim.fn.maparg('<C-,>', 't'))
  eq('<Cmd>ToggleAgent<CR>', vim.fn.maparg('<F9>', 'n'))
end

local ok, err = xpcall(run, debug.traceback)
if not ok then
  io.stderr:write(err .. '\n')
  vim.cmd.cquit({ bang = true })
end
print('Multi-agent integration checks passed')
vim.cmd.quitall({ bang = true })
