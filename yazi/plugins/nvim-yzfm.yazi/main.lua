--- @sync entry

local M = {}
local eventOpen = 'nvim-yzfm-open'
local resizeEvent = 'nvim-yzfm-resize'
local fileEvent = 'nvim-yzfm-files'
local fileEventKinds = {'rename', 'bulk-rename', 'move', 'trash', 'delete'}
local fileEventsSubscribed = false
local viewMode = {
    settings = {
        large = {ratio = {5, 8, 12}, min_width = 90},
        tiny = {ratio = {1, 1, 0}, min_width = 50, max_width = 89},
        small = {ratio = {0, 1, 0}, max_width = 49},
    },
    subscribed = false,
}

local function copyRatio(value, fallback)
    if type(value) ~= 'table' then
        return fallback
    end
    for index = 1, 3 do
        if type(value[index]) ~= 'number' then
            return fallback
        end
    end
    return {value[1], value[2], value[3]}
end

local function copyView(value, fallback)
    if type(value) ~= 'table' then
        return fallback
    end
    return {
        ratio = copyRatio(value.ratio, fallback.ratio),
        min_width = tonumber(value.min_width) or fallback.min_width,
        max_width = tonumber(value.max_width) or fallback.max_width,
    }
end

local function applyViewModeSettings(options)
    if type(options) ~= 'table' then
        return
    end
    viewMode.settings.large = copyView(options.large, viewMode.settings.large)
    viewMode.settings.small = copyView(options.small, viewMode.settings.small)
    viewMode.settings.tiny = copyView(options.tiny, viewMode.settings.tiny)
end

local function currentRatio()
    local ratio = rt.mgr.ratio
    return {ratio[1], ratio[2], ratio[3]}
end

local function sameRatio(left, right)
    return left[1] == right[1] and left[2] == right[2] and left[3] == right[3]
end

local function setRatio(ratio)
    if sameRatio(currentRatio(), ratio) then
        return
    end
    rt.mgr.ratio = {ratio[1], ratio[2], ratio[3]}
    ya.emit('app:resize', {})
end

local function ratioForWidth(width)
    for _, name in ipairs({'large', 'tiny', 'small'}) do
        local view = viewMode.settings[name]
        local aboveMin = not view.min_width or width >= view.min_width
        local belowMax = not view.max_width or width <= view.max_width
        if aboveMin and belowMax then
            return view.ratio
        end
    end
    return viewMode.settings.large.ratio
end

local function onResize(payload)
    if type(payload) ~= 'table' then
        return
    end
    local width = tonumber(payload.width)
    if not width then
        return
    end
    setRatio(ratioForWidth(width))
end

local function pathString(value)
    if value == nil then
        return nil
    end
    local path = tostring(value)
    return path ~= '' and path or nil
end

local function appendChange(changes, from, to)
    from, to = pathString(from), pathString(to)
    if from and to then
        changes[#changes + 1] = {from = from, to = to}
    end
end

local function appendPaths(paths, values)
    if values == nil then
        return
    end
    pcall(function()
        for _, value in pairs(values) do
            local path = pathString(value)
            if path then
                paths[#paths + 1] = path
            end
        end
    end)
end

local function publishFileEvent(kind, body)
    if kind == 'rename' then
        local changes = {}
        appendChange(changes, body and body.from, body and body.to)
        if #changes > 0 then
            ps.pub_to(0, fileEvent, {kind = kind, changes = changes})
        end
        return
    end

    if kind == 'bulk-rename' then
        local changes = {}
        pcall(function()
            for from, to in pairs(body) do
                appendChange(changes, from, to)
            end
        end)
        if #changes > 0 then
            ps.pub_to(0, fileEvent, {kind = kind, changes = changes})
        end
        return
    end

    if kind == 'move' then
        local changes = {}
        pcall(function()
            for _, item in pairs(body and body.items or {}) do
                appendChange(changes, item.from, item.to)
            end
        end)
        if #changes > 0 then
            ps.pub_to(0, fileEvent, {kind = kind, changes = changes})
        end
        return
    end

    if kind == 'trash' or kind == 'delete' then
        local paths = {}
        appendPaths(paths, body and body.urls)
        if #paths > 0 then
            ps.pub_to(0, fileEvent, {kind = kind, paths = paths})
        end
    end
end

local function subscribeFileEvents()
    if fileEventsSubscribed then
        return
    end
    fileEventsSubscribed = true
    for _, kind in ipairs(fileEventKinds) do
        pcall(function()
            ps.sub(kind, function(body)
                publishFileEvent(kind, body)
            end)
        end)
    end
end

function viewMode:setup(options)
    applyViewModeSettings(options)
    local initialWidth = type(options) == 'table' and tonumber(options.initial_width)
    if initialWidth then
        setRatio(ratioForWidth(initialWidth))
    end
    if self.subscribed then
        return
    end
    self.subscribed = true
    ps.sub_remote(resizeEvent, onResize)
end

function viewMode:toggle()
    local ratio = currentRatio()
    if sameRatio(ratio, self.settings.small.ratio) then
        setRatio(self.settings.tiny.ratio)
    elseif sameRatio(ratio, self.settings.tiny.ratio) then
        setRatio(self.settings.large.ratio)
    else
        setRatio(self.settings.small.ratio)
    end
end

local function keybindingPayload(job, action, paths)
    local payload = {
        action = action or 'edit',
        paths = paths,
    }
    if job.args.keybinding then
        payload.mode = action or 'edit'
        if job.args.picker == 'false' or job.args.picker == false then
            payload.picker = false
        end
    end
    return payload
end

local function selectedFiles()
    local paths = {}
    local hasDirectory = false

    for _, file in pairs(cx.active.selected) do
        if file.cha.is_dir then
            hasDirectory = true
        else
            paths[#paths + 1] = tostring(file.url)
        end
    end

    if #paths == 0 and cx.active.current.hovered then
        if cx.active.current.hovered.cha.is_dir then
            hasDirectory = true
        else
            paths[1] = tostring(cx.active.current.hovered.url)
        end
    end
    return paths, hasDirectory
end

function M:setup(options)
    viewMode:setup(options)
    subscribeFileEvents()
    return self
end

function M:entry(job)
    local action = job.args[1]

    if action == 'viewmode' then
        viewMode:toggle()
        return
    end

    local paths, hasDirectory = selectedFiles()
    if #paths == 0 and hasDirectory then
        ps.pub_to(0, eventOpen, keybindingPayload(job, action, {}))
        ya.emit('enter', {})
        return
    end
    if #paths == 0 then
        return
    end

    ps.pub_to(0, eventOpen, keybindingPayload(job, action, paths))
end

return M
