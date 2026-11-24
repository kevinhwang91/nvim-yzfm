local api = vim.api
local config = require('yzfm.config')
local notify = require('yzfm.notify')

local M = {}

local function normalWindow(preferred, tabpage)
    local function isNormal(win)
        if not win or not api.nvim_win_is_valid(win) then
            return false
        end
        return api.nvim_win_get_config(win).relative == ''
    end

    if isNormal(preferred) then
        return preferred
    end

    if tabpage and api.nvim_tabpage_is_valid(tabpage) then
        for _, win in ipairs(api.nvim_tabpage_list_wins(tabpage)) do
            if isNormal(win) then
                return win
            end
        end
    end

    for _, win in ipairs(api.nvim_list_wins()) do
        if isNormal(win) then
            return win
        end
    end
end

function M.restoreOrigin(tabpage, win)
    if tabpage and api.nvim_tabpage_is_valid(tabpage) then
        pcall(api.nvim_set_current_tabpage, tabpage)
    end
    local target = normalWindow(win, tabpage)
    if target then
        pcall(api.nvim_set_current_win, target)
    end
end

function M.captureOrigin()
    local tabpage = api.nvim_get_current_tabpage()
    local win = normalWindow(api.nvim_get_current_win(), tabpage)
    return tabpage, win or api.nvim_get_current_win()
end

function M.currentEntry()
    local path = vim.fn.expand('%:p')
    if vim.fn.filereadable(path) == 1 then
        return path
    elseif vim.fn.isdirectory(path) == 1 then
        return path
    end
    return vim.fn.getcwd()
end

function M.currentDirectory()
    local entry = M.currentEntry()
    if vim.fn.filereadable(entry) == 1 then
        return vim.fn.fnamemodify(entry, ':h')
    end
    return entry
end

function M.selectedPaths(path)
    if not path or vim.fn.filereadable(path) ~= 1 then
        return {}
    end
    local paths = {}
    for _, value in ipairs(vim.fn.readfile(path)) do
        if value ~= '' then
            paths[#paths + 1] = value
        end
    end
    return paths
end

local function getOpenCommand(openMode)
    local mode = config.openMode[openMode] and openMode or 'edit'
    return mode == 'edit' and 'drop' or mode
end

function M.openPaths(paths, openMode, originTab, originWin)
    M.restoreOrigin(originTab, originWin)

    local command = getOpenCommand(openMode)
    local ok, errorMessage = pcall(function()
        vim.cmd({cmd = command, args = {paths[1]}, mods = {silent = true}})
        for index = 2, #paths do
            vim.cmd({cmd = 'badd', args = {paths[index]}, mods = {silent = true}})
        end
    end)
    if not ok then
        notify(errorMessage, vim.log.levels.ERROR)
    end
    return ok
end

return M
