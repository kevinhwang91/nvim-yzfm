local keymap = require('yzfm.keymap')
local notify = require('yzfm.notify')

local M = {}
local customKeyBindings = {}

local moduleFile = debug.getinfo(1, 'S').source:sub(2)
local pluginRoot = vim.fn.fnamemodify(moduleFile, ':h:h:h')
local fixedYaziConfig = pluginRoot .. '/yazi'
local effectiveYaziConfig = vim.fn.stdpath('cache') .. '/nvim-yzfm/yazi'

M.openMode = {
    edit = 'edit',
    split = 'split',
    vsplit = 'vsplit',
    tabedit = 'tabedit',
}

local function defaultYaziConfigHome()
    local configured = vim.env.YAZI_CONFIG_HOME
    if configured and configured ~= '' and configured:sub(1, 1) == '/' then
        return vim.fn.fnamemodify(configured, ':p')
    end

    local xdg = vim.env.XDG_CONFIG_HOME
    if xdg and xdg ~= '' and xdg:sub(1, 1) == '/' then
        return vim.fn.fnamemodify(xdg .. '/yazi', ':p')
    end
    return vim.fn.expand('~/.config/yazi')
end

local defaults = {
    yazi = 'yazi',
    ya = 'ya',
    args = {},
    floating_window = {
        presets = {
            {width = 0.60, height = 0.60},
            {width = 0.80, height = 0.80},
            {width = 0.86, height = 0.86},
            {width = 0.95, height = 0.95},
        },
        preset = 3,
        border = 'single',
        border_highlight = 'YaziBorder',
        shadow = 70,
        title = nil,
        title_pos = 'center',
    },
    key_bindings = {
        ['<C-o>'] = {mode = 'edit'},
        ['<C-x>'] = {mode = 'split'},
        ['<C-v>'] = {mode = 'vsplit'},
        ['<C-t>'] = {mode = 'tabedit'},
    },
    key_maps = {},
}

local function pathJoin(parent, child)
    if parent:sub(-1) == '/' then
        return parent .. child
    end
    return parent .. '/' .. child
end

local function absolutePath(path)
    if type(path) ~= 'string' or path == '' then
        return nil
    end
    return vim.fn.fnamemodify(vim.fn.expand(path), ':p')
end

local function uvLstat(path)
    local uv = vim.uv or vim.loop
    return uv and uv.fs_lstat(path) or nil
end

local function pathExists(path)
    return uvLstat(path) ~= nil
end

local function mkdir(path)
    if vim.fn.isdirectory(path) == 1 then
        return true
    end
    return vim.fn.mkdir(path, 'p') == 1
end

local function unlink(path)
    if not pathExists(path) then
        return true
    end
    local uv = vim.uv or vim.loop
    if uv and uv.fs_unlink then
        local ok = uv.fs_unlink(path)
        if ok then
            return true
        end
    end
    return vim.fn.delete(path) == 0
end

local function symlink(source, target)
    if pathExists(target) then
        return true
    end
    local uv = vim.uv or vim.loop
    if not uv or not uv.fs_symlink then
        return false, 'Neovim does not provide a symlink API'
    end
    local ok, result, errorMessage = pcall(uv.fs_symlink, source, target)
    if not ok or not result then
        return false, errorMessage or tostring(result)
    end
    return true
end

local function ensurePluginsOverlay(base, home)
    local source = pathJoin(base, 'plugins')
    local fixed = pathJoin(fixedYaziConfig, 'plugins')
    local target = pathJoin(home, 'plugins')
    local targetStat = uvLstat(target)
    if targetStat and targetStat.type == 'link' then
        unlink(target)
        targetStat = nil
    end
    if not targetStat and not mkdir(target) then
        notify('Could not create Yazi plugin overlay: ' .. target, vim.log.levels.WARN)
        return
    end

    for _, name in ipairs(vim.fn.readdir(target)) do
        local child = pathJoin(target, name)
        local stat = uvLstat(child)
        if stat and stat.type == 'link' then
            unlink(child)
        end
    end

    local function linkChildren(directory)
        if vim.fn.isdirectory(directory) ~= 1 then
            return
        end
        for _, name in ipairs(vim.fn.readdir(directory)) do
            local child = pathJoin(directory, name)
            local destination = pathJoin(target, name)
            if not pathExists(destination) then
                local ok, errorMessage = symlink(child, destination)
                if not ok then
                    notify('Could not link Yazi plugin ' .. name .. ': ' .. tostring(errorMessage), vim.log.levels.WARN)
                end
            end
        end
    end

    linkChildren(source)
    linkChildren(fixed)
end

local function configHome()
    local base = absolutePath(defaultYaziConfigHome())
    local home = absolutePath(effectiveYaziConfig)
    return base, home
end

function M.ensureOverlay()
    local base, home = configHome()
    if not home then
        return nil
    end
    if not base or base == home then
        return home
    end
    if not mkdir(home) then
        notify('Could not create Yazi config overlay: ' .. home, vim.log.levels.WARN)
        return base
    end

    for _, name in ipairs(vim.fn.readdir(home)) do
        if name ~= 'keymap.toml' and name ~= 'plugins' then
            local target = pathJoin(home, name)
            local stat = uvLstat(target)
            if stat and stat.type == 'link' then
                unlink(target)
            end
        end
    end

    if vim.fn.isdirectory(base) == 1 then
        for _, name in ipairs(vim.fn.readdir(base)) do
            if name == 'plugins' then
                ensurePluginsOverlay(base, home)
            elseif name ~= 'keymap.toml' then
                local source = pathJoin(base, name)
                local target = pathJoin(home, name)
                if not pathExists(target) then
                    local ok, errorMessage = symlink(source, target)
                    if not ok then
                        notify('Could not link Yazi config ' .. name .. ': ' .. tostring(errorMessage),
                            vim.log.levels.WARN)
                    end
                end
            end
        end
    end
    ensurePluginsOverlay(base, home)

    local keymapTarget = pathJoin(home, 'keymap.toml')
    local keymapSource = pathJoin(base, 'keymap.toml')
    local source = ''
    if vim.fn.filereadable(keymapSource) == 1 then
        source = table.concat(vim.fn.readfile(keymapSource), '\n') .. '\n'
    end
    local decorated = "# Generated by nvim-yzfm from the plugin's fixed Yazi profile.\n" ..
        keymap.decorate(source, pathJoin(fixedYaziConfig, 'keymap.toml'), customKeyBindings, M.openMode)
    local existing = uvLstat(keymapTarget)
    if existing and existing.type == 'link' then
        unlink(keymapTarget)
    elseif existing and vim.fn.filereadable(keymapTarget) == 1 then
        local current = table.concat(vim.fn.readfile(keymapTarget), '\n')
        if not current:match('^# Generated by nvim%-yzfm') then
            notify('Keeping existing Yazi overlay keymap: ' .. keymapTarget, vim.log.levels.WARN)
            return home
        end
    end
    vim.fn.writefile(vim.split(decorated, '\n', {plain = true}), keymapTarget)

    return home
end

function M.setup(userOpts)
    M.options = vim.tbl_deep_extend('force', {}, defaults, userOpts or {})
    customKeyBindings = vim.tbl_extend('force', {}, userOpts and userOpts.key_bindings or {})
end

return M
