--- @sync entry

local M = {}
local eventOpen = 'nvim-yzfm-open'

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

function M:entry(job)
    local action = job.args[1]
    if action == 'quit' then
        ya.emit('quit', {})
        return
    end

    local paths, hasDirectory = selectedFiles()
    if #paths == 0 and hasDirectory then
        ps.pub_to(0, eventOpen, {
            action = action or 'edit',
            paths = {},
        })
        ya.emit('enter', {})
        return
    end
    if #paths == 0 then
        return
    end

    ps.pub_to(0, eventOpen, {
        action = action or 'edit',
        paths = paths,
    })
end

return M
