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

local function absolutePath(path)
    if type(path) ~= 'string' or path == '' or path:match('^[%w+.-]+://') then
        return nil
    end
    local absolute = vim.fn.fnamemodify(path, ':p')
    if absolute == '' then
        return nil
    end
    return vim.fs.normalize(absolute)
end

local function pathMatches(path, root)
    if path == root then
        return true
    end
    local prefix = root == '/' and '/' or root .. '/'
    return path:sub(1, #prefix) == prefix
end

local function mappedPath(path, source, destination)
    if not pathMatches(path, source) then
        return nil
    end
    if path == source then
        return destination
    end
    local suffix = path:sub(#source + 1)
    return destination .. suffix
end

local function bufferPath(buffer)
    if not api.nvim_buf_is_valid(buffer) or not api.nvim_buf_is_loaded(buffer) then
        return nil
    end
    return absolutePath(api.nvim_buf_get_name(buffer))
end

local function namedBufferPath(buffer)
    if not api.nvim_buf_is_valid(buffer) then
        return nil
    end
    return absolutePath(api.nvim_buf_get_name(buffer))
end

local function loadedFileBuffers()
    local buffers = {}
    for _, buffer in ipairs(api.nvim_list_bufs()) do
        local path = bufferPath(buffer)
        if path then
            buffers[#buffers + 1] = {buffer = buffer, path = path}
        end
    end
    return buffers
end

local function saveBufferAs(buffer, target)
    local currentWindow = api.nvim_get_current_win()
    local ok, errorMessage = pcall(function()
        api.nvim_buf_call(buffer, function()
            vim.cmd({cmd = 'saveas', bang = true, args = {target}, mods = {silent = true, noautocmd = true}})
        end)
    end)

    if api.nvim_win_is_valid(currentWindow) then
        pcall(api.nvim_set_current_win, currentWindow)
        local currentBuffer = api.nvim_win_get_buf(currentWindow)
        if vim.bo[currentBuffer].buftype == 'terminal' then
            vim.cmd.startinsert()
        end
    end
    return ok, errorMessage
end

local function deleteBuffer(buffer)
    local normalWindow
    local fallbackWindow
    for _, win in ipairs(api.nvim_list_wins()) do
        if api.nvim_win_get_buf(win) == buffer then
            fallbackWindow = fallbackWindow or win
            if api.nvim_win_get_config(win).relative == '' then
                normalWindow = win
                break
            end
        end
    end

    local targetWindow = normalWindow or fallbackWindow
    local ok = pcall(function()
        if targetWindow and api.nvim_win_is_valid(targetWindow) then
            -- Deleting a buffer displayed behind a floating window otherwise
            -- becomes a no-op in Neovim, even with force=true.
            api.nvim_win_call(targetWindow, function()
                api.nvim_buf_delete(buffer, {force = true})
            end)
        else
            api.nvim_buf_delete(buffer, {force = true})
        end
    end)
    return ok and not api.nvim_buf_is_valid(buffer)
end

local function renameBuffers(changes)
    local buffers = loadedFileBuffers()
    local existingBuffers = {}
    local sources = {}
    for _, buffer in ipairs(api.nvim_list_bufs()) do
        existingBuffers[buffer] = true
    end
    local renamed = 0
    local keptModified = 0
    for _, item in ipairs(changes) do
        local source = absolutePath(item.from)
        local destination = absolutePath(item.to)
        if source and destination then
            sources[#sources + 1] = source
            for _, entry in ipairs(buffers) do
                local target = mappedPath(entry.path, source, destination)
                if target and target ~= entry.path and api.nvim_buf_is_valid(entry.buffer) then
                    if vim.bo[entry.buffer].modified then
                        keptModified = keptModified + 1
                    else
                        local ok, errorMessage = saveBufferAs(entry.buffer, target)
                        if ok then
                            entry.path = target
                            renamed = renamed + 1
                        else
                            notify('Could not update buffer path to ' .. target .. ': ' .. tostring(errorMessage),
                                vim.log.levels.WARN)
                        end
                    end
                end
            end
        end
    end

    -- saveas! creates an unloaded buffer for the old name. Remove only buffers
    -- created by this operation; an existing user buffer with the old path must
    -- remain untouched.
    for _, buffer in ipairs(api.nvim_list_bufs()) do
        if not existingBuffers[buffer] and not api.nvim_buf_is_loaded(buffer) and not vim.bo[buffer].modified then
            local path = namedBufferPath(buffer)
            for _, source in ipairs(sources) do
                if path and pathMatches(path, source) then
                    deleteBuffer(buffer)
                    break
                end
            end
        end
    end
    if keptModified > 0 then
        notify(string.format('Kept %d modified buffer(s) at the old path after Yazi rename', keptModified),
            vim.log.levels.WARN)
    end
    return renamed
end

local function deleteBuffers(paths)
    local roots = {}
    for _, path in ipairs(paths) do
        local root = absolutePath(path)
        if root then
            roots[#roots + 1] = root
        end
    end
    if #roots == 0 then
        return 0
    end

    local deleted = 0
    local kept = 0
    for _, entry in ipairs(loadedFileBuffers()) do
        local matches = false
        for _, root in ipairs(roots) do
            if pathMatches(entry.path, root) then
                matches = true
                break
            end
        end
        if matches then
            if vim.bo[entry.buffer].modified then
                kept = kept + 1
            else
                -- The buffer may still be displayed in a normal window behind
                -- the floating Yazi terminal. It is clean, so force deletion
                -- is safe and ensures it is removed from that hidden window too.
                local ok = deleteBuffer(entry.buffer)
                if ok then
                    deleted = deleted + 1
                end
            end
        end
    end
    if kept > 0 then
        notify(string.format('Kept %d modified buffer(s) after Yazi deletion', kept), vim.log.levels.WARN)
    end
    return deleted
end

function M.applyChanges(payload)
    if type(payload) ~= 'table' or type(payload.kind) ~= 'string' then
        return false
    end

    if payload.kind == 'rename' or payload.kind == 'move' or payload.kind == 'bulk-rename' then
        return renameBuffers(type(payload.changes) == 'table' and payload.changes or {}) > 0
    end
    if payload.kind == 'trash' or payload.kind == 'delete' then
        return deleteBuffers(type(payload.paths) == 'table' and payload.paths or {}) > 0
    end
    return false
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
