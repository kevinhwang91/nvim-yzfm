local api = vim.api

local M = {}

local eventOpen = 'nvim-yzfm-open'
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
    floatingWindow = {
        presets = {
            {width = 0.60, height = 0.60},
            {width = 0.80, height = 0.80},
            {width = 0.86, height = 0.86},
            {width = 0.95, height = 0.95},
        },
        preset = 3,
        border = 'single',
        borderHighlight = 'YaziBorder',
        shadow = 70,
        title = nil,
        titlePos = 'center',
    },
    keyBindings = {
        ['<C-o>'] = {mode = 'edit'},
        ['<C-x>'] = {mode = 'split'},
        ['<C-v>'] = {mode = 'vsplit'},
        ['<C-t>'] = {mode = 'tabedit'},
    },
    keyMaps = {},
}

local state = {
    config = nil,
    buf = nil,
    win = nil,
    shadowBuf = nil,
    shadowWin = nil,
    yaziJob = nil,
    subJob = nil,
    subPartial = '',
    subRetryPending = false,
    effectiveConfigHome = nil,
    clientId = nil,
    chooserFile = nil,
    originWin = nil,
    originTab = nil,
    nextOpenMode = nil,
    nextPicker = nil,
    layoutIndex = 1,
    generation = 0,
    startupOpenScheduled = false,
    startupOpenDone = false,
}

local function notify(message, level)
    vim.schedule(function()
        vim.notify(message, level or vim.log.levels.INFO, {title = 'nvim-yzfm'})
    end)
end

local function defineHighlights()
    api.nvim_set_hl(0, 'YaziNormal', {default = true, link = 'NormalFloat'})
    api.nvim_set_hl(0, 'YaziBorder', {default = true, link = 'FloatBorder'})
end

local function validBuf(buf)
    return buf and api.nvim_buf_is_valid(buf)
end

local function validWin(win)
    return win and api.nvim_win_is_valid(win)
end

local function jobRunning(job)
    return job and vim.fn.jobwait({job}, 0)[1] == -1
end

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

local function emitTo(receiver, action, argument)
    if not receiver then
        return
    end
    local command = {state.config.ya, 'emit-to', tostring(receiver), action}
    if argument then
        command[#command + 1] = argument
    end
    vim.fn.jobstart(command, {
        detach = true,
        stdin = 'null',
        env = state.effectiveConfigHome and {YAZI_CONFIG_HOME = state.effectiveConfigHome} or nil,
    })
end

local function stopSubscriber()
    state.subPartial = ''
    state.subRetryPending = false
    if state.subJob then
        vim.fn.jobstop(state.subJob)
        state.subJob = nil
    end
end

local function parseSubscriberLine(line, generation)
    if generation ~= state.generation then
        return
    end

    local kind, _, sender, body = line:match('^([^,]+),([^,]+),([^,]+),(.*)$')
    if kind ~= eventOpen or not body or
        (state.clientId and sender ~= tostring(state.clientId)) then
        return
    end

    local ok, payload = pcall(vim.json.decode, body)
    if ok and type(payload) == 'table' then
        -- Job callbacks run in a fast event.  Opening a buffer changes windows and
        -- must be deferred to the main Neovim event loop.
        vim.schedule(function()
            if generation == state.generation then
                M.openFiles(payload)
            end
        end)
    end
end

local function readSubscriber(data, generation)
    if generation ~= state.generation or type(data) ~= 'table' then
        return
    end

    -- `jobstart()` strips newlines and returns one item per line; the final
    -- non-empty item is a partial line.  Keep that item until the next callback,
    -- while also accepting raw chunks for older Neovim versions.
    for index, chunk in ipairs(data) do
        local complete = index < #data or chunk == ''
        state.subPartial = state.subPartial .. chunk
        while true do
            local newline = state.subPartial:find('\n', 1, true)
            if not newline then
                break
            end
            local line = state.subPartial:sub(1, newline - 1):gsub('\r$', '')
            state.subPartial = state.subPartial:sub(newline + 1)
            parseSubscriberLine(line, generation)
        end
        if complete and state.subPartial ~= '' then
            parseSubscriberLine(state.subPartial:gsub('\r$', ''), generation)
            state.subPartial = ''
        end
    end
end

local function scheduleSubscriber(generation, delay)
    if generation ~= state.generation or state.subRetryPending then
        return
    end

    state.subRetryPending = true
    vim.defer_fn(function()
        state.subRetryPending = false
        if generation ~= state.generation or state.subJob or not jobRunning(state.yaziJob) then
            return
        end

        local job = vim.fn.jobstart({state.config.ya, 'sub', eventOpen}, {
            stdout_buffered = false,
            stdin = 'null',
            env = state.effectiveConfigHome and {YAZI_CONFIG_HOME = state.effectiveConfigHome} or nil,
            on_stdout = function(_, data)
                readSubscriber(data, generation)
            end,
            on_exit = function(jobId)
                if generation == state.generation and state.subJob == jobId then
                    state.subJob = nil
                    scheduleSubscriber(generation, 250)
                end
            end,
        })
        if job > 0 then
            state.subJob = job
        else
            scheduleSubscriber(generation, 250)
        end
    end, delay or 100)
end

local function normalWindow(preferred, tabpage)
    local function isNormal(win)
        if not validWin(win) then
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

local function restoreOrigin(tabpage, win)
    if tabpage and api.nvim_tabpage_is_valid(tabpage) then
        pcall(api.nvim_set_current_tabpage, tabpage)
    end
    local target = normalWindow(win, tabpage)
    if target then
        pcall(api.nvim_set_current_win, target)
    end
end

local function captureOrigin()
    local tabpage = api.nvim_get_current_tabpage()
    local win = normalWindow(api.nvim_get_current_win(), tabpage)
    state.originTab = tabpage
    state.originWin = win or api.nvim_get_current_win()
end

local function resolveDimension(value, total, minimum)
    if type(value) ~= 'number' then
        return total
    end
    local result = value > 0 and value < 1 and math.floor(total * value) or math.floor(value)
    return math.max(minimum, math.min(total, result))
end

local function layoutOptions()
    local opts = state.config.floatingWindow
    local layout = opts.presets and opts.presets[state.layoutIndex] or nil
    return layout or opts
end

local function windowConfig()
    local opts = state.config.floatingWindow
    local layout = layoutOptions()
    local width = resolveDimension(layout.width, math.max(vim.o.columns - 2, 1), 1)
    local height = resolveDimension(layout.height, math.max(vim.o.lines - 2, 1), 1)
    local config = {
        relative = 'editor',
        width = width,
        height = height,
        row = math.max(0, math.floor((vim.o.lines - height) / 2 - 1)),
        col = math.max(0, math.floor((vim.o.columns - width) / 2)),
        style = 'minimal',
        border = opts.border,
    }

    if opts.title then
        config.title = opts.title
        config['title_pos'] = opts.titlePos or 'center'
    end
    return config
end

local function shadowConfig()
    return {
        relative = 'editor',
        focusable = false,
        width = vim.o.columns,
        height = vim.o.lines,
        row = 0,
        col = 0,
        style = 'minimal',
        zindex = 1,
    }
end

local function shadowBlend()
    local value = state.config.floatingWindow.shadow
    if value == false then
        return nil
    end
    if type(value) ~= 'number' then
        return 70
    end
    return math.max(0, math.min(100, math.floor(value)))
end

local function showShadow()
    local blend = shadowBlend()
    if blend == nil or validWin(state.shadowWin) then
        return
    end

    local buffer = state.shadowBuf
    if not validBuf(buffer) then
        buffer = api.nvim_create_buf(false, true)
        state.shadowBuf = buffer
        vim.bo[buffer].bufhidden = 'wipe'
        api.nvim_create_autocmd('BufWipeout', {
            buffer = buffer,
            once = true,
            callback = function()
                if state.shadowBuf == buffer then
                    state.shadowBuf = nil
                end
            end,
        })
    end

    state.shadowWin = api.nvim_open_win(buffer, false, shadowConfig())
    vim.wo[state.shadowWin].winhl = 'Normal:Normal'
    vim.wo[state.shadowWin].winblend = blend
end

local function closeShadow()
    local win = state.shadowWin
    local buffer = state.shadowBuf
    state.shadowWin = nil
    state.shadowBuf = nil
    if validWin(win) then
        pcall(api.nvim_win_close, win, true)
    end
    if validBuf(buffer) then
        pcall(api.nvim_buf_delete, buffer, {force = true})
    end
end

local function resizeWindow()
    if validWin(state.win) then
        api.nvim_win_set_config(state.win, windowConfig())
    end
    if validWin(state.shadowWin) then
        api.nvim_win_set_config(state.shadowWin, shadowConfig())
    end
    vim.cmd('redraw')
end

local function cycleLayout()
    local presets = state.config.floatingWindow.presets
    if type(presets) ~= 'table' or #presets == 0 then
        return
    end
    state.layoutIndex = state.layoutIndex % #presets + 1
    resizeWindow()
end

local function selectInitialLayout()
    local opts = state.config.floatingWindow
    local presets = opts.presets or {}
    local preset = type(opts.preset) == 'number' and math.floor(opts.preset) or 1
    if #presets == 0 then
        state.layoutIndex = 1
        return
    end
    state.layoutIndex = math.max(1, math.min(preset, #presets))
end

local function currentEntry()
    local path = vim.fn.expand('%:p')
    if vim.fn.filereadable(path) == 1 then
        return path
    elseif vim.fn.isdirectory(path) == 1 then
        return path
    end
    return vim.fn.getcwd()
end

local function currentDirectory()
    local entry = currentEntry()
    if vim.fn.filereadable(entry) == 1 then
        return vim.fn.fnamemodify(entry, ':h')
    end
    return entry
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

local function fixedKeymapEntries()
    local path = pathJoin(fixedYaziConfig, 'keymap.toml')
    if vim.fn.filereadable(path) ~= 1 then
        return ''
    end

    local lines = vim.fn.readfile(path)
    local result = {}
    local inside = false
    for _, line in ipairs(lines) do
        if not inside and line:match('^%s*prepend_keymap%s*=%s*%[%s*$') then
            inside = true
        elseif inside and line:match('^%s*%]%s*,?%s*$') then
            break
        elseif inside then
            result[#result + 1] = line
        end
    end
    return table.concat(result, '\n')
end

local function decorateKeymap(source, rendered)
    if rendered == '' then
        return source
    end

    local tableStart = source:find('%[%[mgr%.prepend_keymap%]%]')
    if tableStart then
        return source:sub(1, tableStart - 1) .. rendered .. '\n' .. source:sub(tableStart)
    end

    local _, arrayEnd = source:find('prepend_keymap%s*=%s*%[')
    if arrayEnd then
        local lineEnd = source:find('\n', arrayEnd, true)
        if not lineEnd then
            lineEnd = #source + 1
        end
        return source:sub(1, lineEnd) .. rendered .. '\n' .. source:sub(lineEnd + 1)
    end

    local _, keymapEnd = source:find('keymap%s*=%s*%[')
    if keymapEnd then
        local lineEnd = source:find('\n', keymapEnd, true)
        if not lineEnd then
            lineEnd = #source + 1
        end
        return source:sub(1, lineEnd) .. rendered .. '\n' .. source:sub(lineEnd + 1)
    end

    local mgrStart, mgrEnd = source:find('%[mgr%]%s*\n')
    local block = 'prepend_keymap = [\n' .. rendered .. '\n]\n'
    if mgrStart then
        return source:sub(1, mgrEnd) .. block .. source:sub(mgrEnd + 1)
    end
    return '[mgr]\n' .. block .. '\n' .. source
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

local function ensureYaziConfig()
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
        decorateKeymap(source, fixedKeymapEntries())
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

local function buildYaziCommand(opts)
    local configHome = ensureYaziConfig()
    state.effectiveConfigHome = configHome
    state.clientId = string.format('%.0f', vim.fn.localtime() * 1000000 + vim.fn.getpid() + state.generation)
    state.chooserFile = vim.fn.tempname()

    local command = {
        state.config.yazi,
        '--chooser-file',
        state.chooserFile,
        '--client-id',
        state.clientId,
    }
    for _, arg in ipairs(state.config.args) do
        command[#command + 1] = arg
    end
    for _, arg in ipairs(opts.args or {}) do
        command[#command + 1] = arg
    end

    local entry = opts.path or currentDirectory()
    if entry then
        command[#command + 1] = entry
    end
    return command, configHome
end

local function ensureBuffer()
    if validBuf(state.buf) then
        return state.buf
    end

    state.buf = api.nvim_create_buf(false, true)
    local buffer = state.buf
    vim.bo[buffer].bufhidden = 'hide'
    vim.bo[buffer].buflisted = false
    vim.bo[buffer].swapfile = false
    vim.bo[buffer].filetype = 'yazi'
    api.nvim_create_autocmd('BufWipeout', {
        buffer = buffer,
        once = true,
        callback = function()
            if state.buf == buffer then
                state.buf = nil
            end
        end,
    })
    return buffer
end

local function windowHighlight()
    local borderHighlight = state.config.floatingWindow.borderHighlight
    if type(borderHighlight) ~= 'string' or borderHighlight == '' then
        return 'Normal:YaziNormal'
    end
    return 'Normal:YaziNormal,FloatBorder:' .. borderHighlight
end

local function showWindow()
    if not validBuf(state.buf) then
        return false
    end
    if validWin(state.win) then
        showShadow()
        vim.wo[state.win].winhl = windowHighlight()
        api.nvim_set_current_win(state.win)
        return true
    end

    showShadow()
    state.win = api.nvim_open_win(state.buf, true, windowConfig())
    vim.wo[state.win].winhl = windowHighlight()
    vim.wo[state.win].winblend = 0
    return true
end

local function closeWindow()
    local win = state.win
    state.win = nil
    if validWin(win) then
        pcall(api.nvim_win_close, win, true)
    end
    closeShadow()
end

local function showWindowOnly()
    if not showWindow() then
        return false
    end
    vim.cmd.startinsert()
    return true
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
    stopSubscriber()
    closeWindow()
    local buf = state.buf
    state.buf = nil
    if validBuf(buf) then
        pcall(api.nvim_buf_delete, buf, {force = true})
    end
    cleanupFiles()
    if stopJob and job and jobRunning(job) then
        vim.fn.jobstop(job)
    end
end

local function selectedPaths(path)
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
    local mode = M.openMode[openMode] and openMode or 'edit'
    return mode == 'edit' and 'drop' or mode, mode
end

local function pickerEnabled(value)
    return value ~= false
end

local function openPaths(paths, openMode, originTab, originWin, keepFloat)
    if #paths == 0 then
        return
    end

    if originTab and api.nvim_tabpage_is_valid(originTab) then
        pcall(api.nvim_set_current_tabpage, originTab)
    end
    local targetWin = normalWindow(originWin, originTab)
    if targetWin then
        pcall(api.nvim_set_current_win, targetWin)
    end

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

    if keepFloat and validWin(state.win) then
        if originTab and api.nvim_tabpage_is_valid(originTab) then
            pcall(api.nvim_set_current_tabpage, originTab)
        end
        pcall(api.nvim_set_current_win, state.win)
        vim.cmd.startinsert()
    elseif ok then
        -- Keep Yazi alive in the background so the next toggle can reuse it.
        closeWindow()
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
        -- Directory actions do not open a Neovim buffer, but they must still
        -- consume any per-key picker override recorded for the action.
        state.nextOpenMode = nil
        state.nextPicker = nil
        return
    end

    local action = payload.action or 'edit'
    if action == 'edit' and state.nextOpenMode then
        action = state.nextOpenMode
    end
    local picker = state.nextPicker
    state.nextOpenMode = nil
    state.nextPicker = nil
    openPaths(paths, action, state.originTab, state.originWin, not pickerEnabled(picker))
end

local function finish(generation)
    if generation ~= state.generation then
        return
    end

    local selected = selectedPaths(state.chooserFile)
    local originTab = state.originTab
    local originWin = state.originWin
    local openMode = state.nextOpenMode

    teardown(false)
    restoreOrigin(originTab, originWin)
    openPaths(selected, openMode, originTab, originWin)
    state.originTab = nil
    state.originWin = nil
    state.nextOpenMode = nil
    state.nextPicker = nil
end

local function setTerminalKeybindings(buffer)
    for key, value in pairs(state.config.keyBindings or {}) do
        local mode = value
        local picker
        if type(value) == 'table' then
            mode = value.mode
            if value.picker ~= nil then
                picker = value.picker == true
            end
        end
        if M.openMode[mode] then
            vim.keymap.set('t', key, function()
                M.setNextOpenMode(mode)
                M.setNextPicker(picker)
                if state.yaziJob then
                    vim.schedule(function()
                        if jobRunning(state.yaziJob) then
                            local termcode = api.nvim_replace_termcodes(key, true, false, true)
                            vim.fn.chansend(state.yaziJob, termcode)
                        end
                    end)
                end
            end, {buffer = buffer, silent = true, nowait = true, desc = 'Yazi: ' .. mode})
        end
    end
end

local function startYazi(opts)
    state.generation = state.generation + 1
    local generation = state.generation
    state.nextOpenMode = opts.openMode
    state.nextPicker = nil
    captureOrigin()
    ensureBuffer()
    showWindow()

    local command, configHome = buildYaziCommand(opts)
    local job = vim.fn.termopen(command, {
        cwd = opts.cwd or vim.fn.getcwd(),
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
    if job <= 0 then
        teardown(false)
        notify('Could not start Yazi', vim.log.levels.ERROR)
        return false
    end

    state.yaziJob = job
    -- Yazi needs a moment to publish its DDS endpoint after termopen.  Starting
    -- `ya sub` immediately can race that initialization and leave a subscriber
    -- attached to a dead endpoint.
    scheduleSubscriber(generation, 1000)
    setTerminalKeybindings(state.buf)
    vim.cmd.startinsert()
    return true
end

local function active()
    return jobRunning(state.yaziJob) and validBuf(state.buf)
end

local function startupDirectory()
    if vim.fn.argc() ~= 1 then
        return nil
    end

    local argument = vim.fn.argv(0)
    if argument == '' or vim.fn.isdirectory(argument) ~= 1 then
        return nil
    end
    return absolutePath(argument)
end

local function replaceStartupDirectoryBuffer(directory)
    local buffer = api.nvim_get_current_buf()
    if not validBuf(buffer) or vim.bo[buffer].buftype ~= '' or vim.bo[buffer].modified or vim.wo.diff then
        return
    end
    if vim.fn.buflisted(buffer) ~= 1 then
        return
    end

    local currentPath = vim.fn.expand('%:p')
    if currentPath == '' or vim.fn.resolve(currentPath) ~= vim.fn.resolve(directory) then
        return
    end

    local replacement = api.nvim_create_buf(false, true)
    vim.bo[replacement].bufhidden = 'wipe'
    vim.bo[replacement].buftype = 'nofile'
    vim.bo[replacement].swapfile = false
    api.nvim_set_current_buf(replacement)
    pcall(api.nvim_buf_delete, buffer, {force = true})
end

local function scheduleStartupDirectory()
    if state.startupOpenScheduled or state.startupOpenDone then
        return
    end

    local directory = startupDirectory()
    if not directory then
        return
    end

    state.startupOpenScheduled = true
    vim.schedule(function()
        state.startupOpenScheduled = false
        if state.startupOpenDone or active() or vim.wo.diff then
            return
        end
        if vim.fn.argc() ~= 1 or vim.fn.isdirectory(directory) ~= 1 then
            return
        end

        replaceStartupDirectoryBuffer(directory)
        state.startupOpenDone = true
        M.open(directory)
    end)
end

function M.setup(userOpts)
    state.config = vim.tbl_deep_extend('force', {}, defaults, userOpts or {})
    defineHighlights()
    selectInitialLayout()
    ensureYaziConfig()

    local group = api.nvim_create_augroup('nvim-yzfm', {clear = true})
    api.nvim_create_autocmd('ColorScheme', {
        group = group,
        callback = defineHighlights,
    })
    api.nvim_create_autocmd('VimResized', {
        group = group,
        callback = resizeWindow,
    })

    api.nvim_create_user_command('Yazi', function(command)
        if command.args ~= '' and active() then
            M.reveal(command.args)
        else
            M.open(command.args ~= '' and command.args or nil)
        end
    end, {nargs = '?', complete = 'file', force = true})
    api.nvim_create_user_command('YaziToggle', function()
        M.toggle()
    end, {force = true})
    api.nvim_create_user_command('YaziResize', function()
        cycleLayout()
    end, {force = true})
    api.nvim_create_user_command('YaziReveal', function()
        M.reveal()
    end, {force = true})
    api.nvim_create_user_command('YaziSplit', function()
        M.open(nil, M.openMode.split)
    end, {force = true})
    api.nvim_create_user_command('YaziVsplit', function()
        M.open(nil, M.openMode.vsplit)
    end, {force = true})
    api.nvim_create_user_command('YaziTabedit', function()
        M.open(nil, M.openMode.tabedit)
    end, {force = true})
    api.nvim_create_user_command('YaziConfig', function()
        local _, home = configHome()
        vim.notify(home, vim.log.levels.INFO, {title = 'nvim-yzfm Yazi config'})
    end, {force = true})

    local maps = state.config.keyMaps
    if maps.toggle then
        vim.keymap.set('n', maps.toggle, '<Cmd>YaziToggle<CR>', {silent = true, desc = 'Toggle Yazi'})
        vim.keymap.set('t', maps.toggle, '<C-\\><C-n><Cmd>YaziToggle<CR>', {silent = true, desc = 'Toggle Yazi'})
    end
    if maps.resize then
        vim.keymap.set('n', maps.resize, cycleLayout, {silent = true, desc = 'Resize Yazi'})
        vim.keymap.set('t', maps.resize, cycleLayout, {silent = true, desc = 'Resize Yazi'})
    end

    scheduleStartupDirectory()
    return M
end

function M.isConfigured()
    return state.config ~= nil
end

local function openProcess(path, openMode)
    if state.config == nil then
        M.setup()
    end
    if active() then
        if openMode then
            M.setNextOpenMode(openMode)
        end
        if path then
            M.reveal(path)
        elseif not validWin(state.win) then
            showWindowOnly()
        end
        return true
    end
    if state.yaziJob then
        teardown(true)
    end
    return startYazi({path = path, openMode = openMode})
end

function M.open(path, openMode)
    return openProcess(path, openMode)
end

function M.toggle(opts)
    if active() then
        if validWin(state.win) then
            closeWindow()
            restoreOrigin(state.originTab, state.originWin)
        else
            showWindowOnly()
        end
        return true
    end

    return M.open(opts and opts.path or currentEntry(), opts and opts.openMode or nil)
end

function M.hide()
    if active() then
        closeWindow()
        restoreOrigin(state.originTab, state.originWin)
    end
end

function M.show()
    if active() then
        if validWin(state.win) then
            showWindow()
        else
            showWindowOnly()
        end
    else
        M.open()
    end
end

function M.resize()
    cycleLayout()
end

function M.reveal(path)
    if not active() then
        M.open(path)
        return
    end
    local target = path or currentEntry()
    emitTo(state.clientId, 'reveal', target)
end

function M.setNextOpenMode(openMode)
    if openMode ~= nil and not M.openMode[openMode] then
        notify('Unknown Yazi open mode: ' .. tostring(openMode), vim.log.levels.WARN)
        return
    end
    state.nextOpenMode = openMode
end

function M.setNextPicker(picker)
    if picker ~= nil and type(picker) ~= 'boolean' then
        notify('Picker must be a boolean or nil', vim.log.levels.WARN)
        return
    end
    state.nextPicker = picker
end

return M
