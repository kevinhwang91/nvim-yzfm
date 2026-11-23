if vim.g.loaded_nvim_yzfm then
  return
end
vim.g.loaded_nvim_yzfm = true

local yazi = require("nvim-yzfm")
if not yazi.is_configured() then
  yazi.setup()
end
