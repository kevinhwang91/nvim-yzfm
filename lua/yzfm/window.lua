local api = vim.api
local config = require('yzfm.config')

local M = {}
local state = {layoutIndex = 1}

function M.defineHighlights()
    api.nvim_set_hl(0, 'YaziNormal', {default = true, link = 'NormalFloat'})
    api.nvim_set_hl(0, 'YaziBorder', {default = true, link = 'FloatBorder'})
end

local function validBuf(buf)
    return buf and api.nvim_buf_is_valid(buf)
end

local function validWin(win)
    return win and api.nvim_win_is_valid(win)
end

local function resolveDimension(value, total, minimum)
    if type(value) ~= 'number' then
        return total
    end
    local result = value > 0 and value < 1 and math.floor(total * value) or math.floor(value)
    return math.max(minimum, math.min(total, result))
end

local function windowConfig()
    local opts = config.options.floating_window
    local layout = opts.presets and opts.presets[state.layoutIndex] or opts
    local width = resolveDimension(layout.width, math.max(vim.o.columns - 2, 1), 1)
    local height = resolveDimension(layout.height, math.max(vim.o.lines - 2, 1), 1)
    local winConfig = {
        relative = 'editor',
        width = width,
        height = height,
        row = math.max(0, math.floor((vim.o.lines - height) / 2 - 1)),
        col = math.max(0, math.floor((vim.o.columns - width) / 2)),
        style = 'minimal',
        border = opts.border,
    }

    if opts.title then
        winConfig.title = opts.title
        winConfig.title_pos = opts.title_pos or 'center'
    end
    return winConfig
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
    local value = config.options.floating_window.shadow
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

function M.resize()
    if validWin(state.win) then
        api.nvim_win_set_config(state.win, windowConfig())
    end
    if validWin(state.shadowWin) then
        api.nvim_win_set_config(state.shadowWin, shadowConfig())
    end
    vim.cmd('redraw')
end

function M.cycleLayout()
    local presets = config.options.floating_window.presets
    if type(presets) ~= 'table' or #presets == 0 then
        return false
    end
    state.layoutIndex = state.layoutIndex % #presets + 1
    M.resize()
    return true
end

function M.selectInitialLayout()
    local opts = config.options.floating_window
    local presets = opts.presets or {}
    local preset = type(opts.preset) == 'number' and math.floor(opts.preset) or 1
    if #presets == 0 then
        state.layoutIndex = 1
        return
    end
    state.layoutIndex = math.max(1, math.min(preset, #presets))
end

function M.ensureBuffer()
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
    local borderHighlight = config.options.floating_window.border_highlight
    if type(borderHighlight) ~= 'string' or borderHighlight == '' then
        return 'Normal:YaziNormal'
    end
    return 'Normal:YaziNormal,FloatBorder:' .. borderHighlight
end

function M.show()
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

function M.close()
    local win = state.win
    state.win = nil
    if validWin(win) then
        pcall(api.nvim_win_close, win, true)
    end
    closeShadow()
end

function M.enterTerminal()
    if not M.show() then
        return false
    end
    vim.cmd.startinsert()
    return true
end

function M.isVisible()
    return validWin(state.win)
end

function M.hasBuffer()
    return validBuf(state.buf)
end

function M.currentSize()
    local winConfig
    if validWin(state.win) then
        local ok
        ok, winConfig = pcall(api.nvim_win_get_config, state.win)
        if not ok or type(winConfig) ~= 'table' then
            return nil
        end
    else
        winConfig = windowConfig()
    end

    if type(winConfig.width) ~= 'number' or type(winConfig.height) ~= 'number' then
        return nil
    end

    return {
        width = winConfig.width,
        height = winConfig.height,
        preset = state.layoutIndex,
    }
end

function M.focus()
    pcall(api.nvim_set_current_win, state.win)
    vim.cmd.startinsert()
end

function M.destroy()
    M.close()
    local buffer = state.buf
    state.buf = nil
    if validBuf(buffer) then
        pcall(api.nvim_buf_delete, buffer, {force = true})
    end
end

return M
