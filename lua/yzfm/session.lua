local config = require('yzfm.config')
local dds = require('yzfm.dds')
local files = require('yzfm.files')
local notify = require('yzfm.notify')
local window = require('yzfm.window')

local M = {}
local state = {generation = 0}
local resizeTimer
local observedColumns
local observedLines

local function stopResizeMonitor()
    if not resizeTimer then
        return
    end
    resizeTimer:stop()
    resizeTimer:close()
    resizeTimer = nil
end

local function resizeMonitorTick()
    local columns = vim.o.columns
    local lines = vim.o.lines
    if columns == observedColumns and lines == observedLines then
        return
    end
    observedColumns = columns
    observedLines = lines
    if M.active() and window.isVisible() then
        M.resizeWindow()
    end
end

local function startResizeMonitor()
    if resizeTimer then
        return
    end

    local uv = vim.uv or vim.loop
    if not uv or not uv.new_timer then
        return
    end

    observedColumns = vim.o.columns
    observedLines = vim.o.lines
    resizeTimer = uv.new_timer()
    resizeTimer:start(100, 100, vim.schedule_wrap(resizeMonitorTick))
end

local function jobRunning(job)
    return job and vim.fn.jobwait({job}, 0)[1] == -1
end

local function buildYaziCommand(entry, initialWidth)
    local configHome = config.ensureOverlay(initialWidth)
    state.effectiveConfigHome = configHome
    state.clientId = string.format('%.0f', vim.fn.localtime() * 1000000 + vim.fn.getpid() + state.generation)
    state.chooserFile = vim.fn.tempname()

    local command = {
        config.options.yazi,
        '--chooser-file',
        state.chooserFile,
        '--client-id',
        state.clientId,
    }
    for _, arg in ipairs(config.options.args) do
        command[#command + 1] = arg
    end
    command[#command + 1] = entry
    return command, configHome
end

local function cleanupFiles()
    if state.chooserFile then
        vim.fn.delete(state.chooserFile)
    end
    state.chooserFile = nil
end

local function teardown(stopJob)
    local job = state.yaziJob
    state.yaziJob = nil
    state.clientId = nil
    state.effectiveConfigHome = nil
    state.generation = state.generation + 1
    dds.unsubscribe()
    stopResizeMonitor()
    window.destroy()
    cleanupFiles()
    if stopJob and job and jobRunning(job) then
        vim.fn.jobstop(job)
    end
end

local function openPaths(paths, openMode, originTab, originWin, keepFloat)
    if #paths == 0 then
        return
    end

    local ok = files.openPaths(paths, openMode, originTab, originWin)
    if keepFloat and window.isVisible() then
        if originTab and vim.api.nvim_tabpage_is_valid(originTab) then
            pcall(vim.api.nvim_set_current_tabpage, originTab)
        end
        window.focus()
    elseif ok then
        -- Keep Yazi alive in the background so the next toggle can reuse it.
        window.close()
    end
end

function M.openFiles(payload)
    if type(payload) ~= 'table' or type(payload.paths) ~= 'table' then
        return
    end

    local paths = {}
    for _, path in ipairs(payload.paths) do
        if type(path) == 'string' and path ~= '' then
            paths[#paths + 1] = path
        end
    end
    if #paths == 0 then
        -- Directory actions do not open a Neovim buffer, but they still finish
        -- the initial open-mode override for this Yazi process.
        state.nextOpenMode = nil
        return
    end

    local action = payload.mode or payload.action or 'edit'
    if not payload.mode and action == 'edit' and state.nextOpenMode then
        action = state.nextOpenMode
    end
    state.nextOpenMode = nil
    openPaths(paths, action, state.originTab, state.originWin, payload.picker == false)
end

local function finish(generation)
    if generation ~= state.generation then
        return
    end

    local selected = files.selectedPaths(state.chooserFile)
    local originTab = state.originTab
    local originWin = state.originWin
    local openMode = state.nextOpenMode

    teardown(false)
    files.restoreOrigin(originTab, originWin)
    openPaths(selected, openMode, originTab, originWin)
    state.originTab = nil
    state.originWin = nil
    state.nextOpenMode = nil
end

local function startYazi(path, openMode)
    state.generation = state.generation + 1
    local generation = state.generation
    state.nextOpenMode = openMode
    local entry = path or files.currentDirectory()
    state.originTab, state.originWin = files.captureOrigin()
    window.ensureBuffer()
    window.show()

    local size = window.currentSize()
    local command, configHome = buildYaziCommand(entry, size and size.width)
    local ok, job = pcall(vim.fn.termopen, command, {
        cwd = vim.fn.getcwd(),
        env = configHome and {YAZI_CONFIG_HOME = configHome} or nil,
        on_exit = function(jobId)
            if generation == state.generation and (state.yaziJob == nil or state.yaziJob == jobId) then
                state.yaziJob = jobId
                vim.schedule(function()
                    finish(generation)
                end)
            end
        end,
    })
    if not ok or job <= 0 then
        teardown(false)
        state.originTab = nil
        state.originWin = nil
        state.nextOpenMode = nil
        notify('Could not start Yazi: ' .. tostring(job), vim.log.levels.ERROR)
        return false
    end

    state.yaziJob = job
    startResizeMonitor()
    dds.subscribe(job, state.clientId, configHome, M.openFiles, files.applyChanges)
    vim.defer_fn(function()
        if generation == state.generation and window.isVisible() then
            window.enterTerminal()
            M.publishResize('open')
        end
    end, 50)
    return true
end

function M.active()
    return jobRunning(state.yaziJob) and window.hasBuffer()
end

function M.publishResize(reason)
    if not M.active() or not state.clientId then
        return false
    end

    local size = window.currentSize()
    if not size then
        return false
    end

    return dds.publishTo(state.clientId, dds.eventResize, {
        width = size.width,
        height = size.height,
        preset = size.preset,
        reason = reason or 'window',
    }, state.effectiveConfigHome)
end

function M.resize()
    local changed = window.cycleLayout()
    if changed then
        M.publishResize('preset')
    end
    return changed
end

function M.resizeWindow()
    observedColumns = vim.o.columns
    observedLines = vim.o.lines
    window.resize()
    return M.publishResize('window')
end

function M.open(path, openMode)
    if M.active() then
        if openMode then
            M.setNextOpenMode(openMode)
        end
        if path then
            M.reveal(path)
        elseif not window.isVisible() then
            window.enterTerminal()
            M.publishResize('show')
        end
        return true
    end
    if state.yaziJob then
        teardown(true)
    end
    return startYazi(path, openMode)
end

function M.toggle(opts)
    if M.active() then
        if window.isVisible() then
            window.close()
            files.restoreOrigin(state.originTab, state.originWin)
        else
            M.publishResize('show')
            window.enterTerminal()
        end
        return true
    end

    return M.open(opts and opts.path or files.currentEntry(), opts and opts.openMode or nil)
end

function M.hide()
    if M.active() then
        window.close()
        files.restoreOrigin(state.originTab, state.originWin)
    end
end

function M.show()
    if M.active() then
        if window.isVisible() then
            window.show()
            M.publishResize('show')
        else
            M.publishResize('show')
            window.enterTerminal()
        end
    else
        M.open()
    end
end

function M.reveal(path)
    if not M.active() then
        M.open(path)
        return
    end
    if not window.isVisible() then
        M.publishResize('show')
        window.enterTerminal()
    end
    local target = path or files.currentEntry()
    dds.emitTo(state.clientId, 'reveal', target, state.effectiveConfigHome)
end

function M.setNextOpenMode(openMode)
    if openMode ~= nil and not config.openMode[openMode] then
        notify('Unknown Yazi open mode: ' .. tostring(openMode), vim.log.levels.WARN)
        return
    end
    state.nextOpenMode = openMode
end

return M
