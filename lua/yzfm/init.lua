local api = vim.api
local config = require('yzfm.config')
local session = require('yzfm.session')
local startup = require('yzfm.startup')
local window = require('yzfm.window')

local M = {
    openMode = config.openMode,
    openFiles = session.openFiles,
    setNextOpenMode = session.setNextOpenMode,
    hide = session.hide,
    resize = window.cycleLayout,
}

function M.setup(userOpts)
    config.setup(userOpts)
    window.defineHighlights()
    window.selectInitialLayout()
    config.ensureOverlay()

    local group = api.nvim_create_augroup('nvim-yzfm', {clear = true})
    api.nvim_create_autocmd('ColorScheme', {
        group = group,
        callback = window.defineHighlights,
    })
    api.nvim_create_autocmd('VimResized', {
        group = group,
        callback = window.resize,
    })

    api.nvim_create_user_command('YaziToggle', function()
        M.toggle()
    end, {force = true})
    api.nvim_create_user_command('YaziResize', M.resize, {force = true})
    api.nvim_create_user_command('YaziSplit', function()
        M.open(nil, M.openMode.split)
    end, {force = true})
    api.nvim_create_user_command('YaziVsplit', function()
        M.open(nil, M.openMode.vsplit)
    end, {force = true})
    api.nvim_create_user_command('YaziTabedit', function()
        M.open(nil, M.openMode.tabedit)
    end, {force = true})

    local maps = config.options.key_maps
    if maps.toggle then
        vim.keymap.set('n', maps.toggle, '<Cmd>YaziToggle<CR>', {silent = true, desc = 'Toggle Yazi'})
        vim.keymap.set('t', maps.toggle, '<C-\\><C-n><Cmd>YaziToggle<CR>', {silent = true, desc = 'Toggle Yazi'})
    end
    if maps.resize then
        vim.keymap.set('n', maps.resize, window.cycleLayout, {silent = true, desc = 'Resize Yazi'})
        vim.keymap.set('t', maps.resize, window.cycleLayout, {silent = true, desc = 'Resize Yazi'})
    end

    startup.schedule(M.open, session.active)
    return M
end

function M.isConfigured()
    return config.options ~= nil
end

local function ensureConfigured()
    if not M.isConfigured() then
        M.setup()
    end
end

function M.open(path, openMode)
    ensureConfigured()
    return session.open(path, openMode)
end

function M.toggle(opts)
    ensureConfigured()
    return session.toggle(opts)
end

function M.show()
    ensureConfigured()
    session.show()
end

function M.reveal(path)
    ensureConfigured()
    session.reveal(path)
end

return M
