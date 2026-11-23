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

local function run()
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

  vim.cmd.OpenAgent()
  local one = api.nvim_get_current_buf()
  eq('cat', vim.fn.fnamemodify(api.nvim_buf_get_name(one), ':t'))
  eq('terminal', vim.bo[one].buftype)
  eq(false, vim.bo[one].buflisted)
  eq('left', api.nvim_win_get_config(0).split)
  eq(math.floor(vim.o.columns * 0.4), api.nvim_win_get_width(0))

  vim.cmd('OpenAgent --mode float cat')
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
  for _, field in ipairs({ 'relative', 'width', 'height', 'row', 'col', 'border' }) do
    eq(agent_float[field], list_float[field])
  end
  eq({ 'cat  [vertical]', 'cat-2  [float]' }, api.nvim_buf_get_lines(0, 0, -1, false))
  eq(2, api.nvim_win_get_cursor(0)[1])
  keys('<Up><Down><Up><CR>')
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
  eq('right', api.nvim_win_get_config(0).split)
  vim.cmd.CloseAgent()
end

local ok, err = xpcall(run, debug.traceback)
if not ok then
  io.stderr:write(err .. '\n')
  vim.cmd.cquit({ bang = true })
end
print('Multi-agent integration checks passed')
vim.cmd.quitall({ bang = true })
