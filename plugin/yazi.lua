if vim.g.loadedNvimYzfm then
    return
end
vim.g.loadedNvimYzfm = true

local yazi = require('nvim-yzfm')
if not yazi.isConfigured() then
    yazi.setup()
end
