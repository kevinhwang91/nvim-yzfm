local api = vim.api

local M = {}
local openScheduled = false
local openDone = false

local function startupDirectory()
    if vim.fn.argc() ~= 1 then
        return nil
    end

    local argument = vim.fn.argv(0)
    if argument == '' or vim.fn.isdirectory(argument) ~= 1 then
        return nil
    end
    return vim.fn.fnamemodify(vim.fn.expand(argument), ':p')
end

local function replaceStartupDirectoryBuffer(directory)
    local target
    local resolvedDirectory = vim.fn.resolve(directory)
    for _, buffer in ipairs(api.nvim_list_bufs()) do
        if api.nvim_buf_is_valid(buffer) and vim.bo[buffer].buftype == '' and not vim.bo[buffer].modified and
            vim.fn.buflisted(buffer) == 1 and vim.fn.resolve(api.nvim_buf_get_name(buffer)) == resolvedDirectory then
            target = buffer
            break
        end
    end
    if not target then
        return false
    end

    if target == api.nvim_get_current_buf() then
        local replacement = api.nvim_create_buf(false, true)
        vim.bo[replacement].bufhidden = 'wipe'
        vim.bo[replacement].buftype = 'nofile'
        vim.bo[replacement].swapfile = false
        api.nvim_set_current_buf(replacement)
    end
    pcall(api.nvim_buf_delete, target, {force = true})
    return true
end

function M.schedule(open, active)
    if openScheduled or openDone then
        return
    end

    local directory = startupDirectory()
    if not directory then
        return
    end

    openScheduled = true
    local function openStartupDirectory()
        openScheduled = false
        if openDone or active() or vim.wo.diff then
            return
        end
        if vim.fn.argc() ~= 1 or vim.fn.isdirectory(directory) ~= 1 then
            return
        end

        replaceStartupDirectoryBuffer(directory)
        openDone = true
        open(directory)
    end

    if vim.v.vim_did_enter == 1 then
        vim.defer_fn(openStartupDirectory, 0)
    else
        local group = api.nvim_create_augroup('nvim-yzfm-startup', {clear = true})
        api.nvim_create_autocmd('VimEnter', {
            group = group,
            once = true,
            callback = function()
                vim.schedule(openStartupDirectory)
            end,
        })
    end
end

return M
