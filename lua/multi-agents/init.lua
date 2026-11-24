local agents = require('multi-agents.agents')
local config = require('claude-code.config')

local M = {
  open = agents.open,
  list = agents.list,
  select = agents.select,
  toggle = agents.toggle,
  reshape = agents.reshape,
  close = agents.close,
}

function M.setup(opts)
  agents.setup(config.parse_config(opts))
end

return M
