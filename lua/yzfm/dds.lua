local config = require('yzfm.config')

local M = {}
local eventOpen = 'nvim-yzfm-open'
local subscription

local function environment(configHome)
    return configHome and {YAZI_CONFIG_HOME = configHome} or nil
end

function M.emitTo(receiver, action, argument, configHome)
    if not receiver then
        return
    end
    local command = {config.options.ya, 'emit-to', tostring(receiver), action}
    if argument then
        command[#command + 1] = argument
    end
    vim.fn.jobstart(command, {
        detach = true,
        stdin = 'null',
        env = environment(configHome),
    })
end

function M.unsubscribe()
    local current = subscription
    subscription = nil
    if current and current.job then
        vim.fn.jobstop(current.job)
    end
end

local function parseSubscriberLine(line, current)
    if subscription ~= current then
        return
    end

    local kind, _, sender, body = line:match('^([^,]+),([^,]+),([^,]+),(.*)$')
    if kind ~= eventOpen or not body or
        (current.clientId and sender ~= tostring(current.clientId)) then
        return
    end

    local ok, payload = pcall(vim.json.decode, body)
    if ok and type(payload) == 'table' then
        -- Job callbacks run in a fast event.  Opening a buffer changes windows and
        -- must be deferred to the main Neovim event loop.
        vim.schedule(function()
            if subscription == current then
                current.onOpen(payload)
            end
        end)
    end
end

local function readSubscriber(data, current)
    if subscription ~= current or type(data) ~= 'table' then
        return
    end

    -- `jobstart()` strips newlines and returns one item per line; the final
    -- non-empty item is a partial line.  Keep that item until the next callback,
    -- while also accepting raw chunks for older Neovim versions.
    for index, chunk in ipairs(data) do
        local complete = index < #data or chunk == ''
        current.partial = current.partial .. chunk
        while true do
            local newline = current.partial:find('\n', 1, true)
            if not newline then
                break
            end
            local line = current.partial:sub(1, newline - 1):gsub('\r$', '')
            current.partial = current.partial:sub(newline + 1)
            parseSubscriberLine(line, current)
        end
        if complete and current.partial ~= '' then
            parseSubscriberLine(current.partial:gsub('\r$', ''), current)
            current.partial = ''
        end
    end
end

local function scheduleSubscriber(current, delay)
    vim.defer_fn(function()
        if subscription ~= current or vim.fn.jobwait({current.yaziJob}, 0)[1] ~= -1 then
            return
        end

        local job = vim.fn.jobstart({config.options.ya, 'sub', eventOpen}, {
            stdout_buffered = false,
            stdin = 'null',
            env = environment(current.configHome),
            on_stdout = function(_, data)
                readSubscriber(data, current)
            end,
            on_exit = function(jobId)
                if subscription == current and current.job == jobId then
                    current.job = nil
                    scheduleSubscriber(current, 250)
                end
            end,
        })
        if job > 0 then
            current.job = job
        else
            scheduleSubscriber(current, 250)
        end
    end, delay)
end

function M.subscribe(yaziJob, clientId, configHome, onOpen)
    subscription = {
        yaziJob = yaziJob,
        clientId = clientId,
        configHome = configHome,
        onOpen = onOpen,
        partial = '',
    }
    -- Wait for Yazi to publish its DDS endpoint before starting `ya sub`.
    scheduleSubscriber(subscription, 100)
end

return M
