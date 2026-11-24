local M = {}

local function fixedKeymapEntries(path)
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

local function tomlString(value)
    return vim.json.encode(tostring(value))
end

local function bindingMode(value)
    if type(value) == 'table' then
        return value.mode, value.picker
    end
    return value, nil
end

local function customKeymapEntries(bindings, openMode)
    local keys = {}
    for key in pairs(bindings) do
        keys[#keys + 1] = key
    end
    table.sort(keys)

    local result = {}
    for _, key in ipairs(keys) do
        local mode, picker = bindingMode(bindings[key])
        if openMode[mode] then
            local run = 'plugin --mode=sync nvim-yzfm -- ' .. mode .. ' --keybinding'
            if picker == false then
                run = run .. ' --picker=false'
            end
            result[#result + 1] = string.format(
                '    { on = %s, run = %s, desc = %s },',
                tomlString(key), tomlString(run), tomlString('Open with ' .. mode)
            )
        end
    end
    return table.concat(result, '\n')
end

local function insertLines(lines, index, additions)
    for offset, line in ipairs(additions) do
        table.insert(lines, index + offset - 1, line)
    end
end

local function renderedLines(rendered)
    return vim.split(rendered, '\n', {plain = true, trimempty = true})
end

local function arrayTableLines(rendered)
    local result = {}
    for _, line in ipairs(renderedLines(rendered)) do
        local on, run, desc = line:match(
            '^%s*{%s*on%s*=%s*(.-),%s*run%s*=%s*(.-),%s*desc%s*=%s*(.-)%s*},?%s*$'
        )
        if not on or not run or not desc then
            return {}
        end
        result[#result + 1] = '[[mgr.prepend_keymap]]'
        result[#result + 1] = 'on = ' .. on
        result[#result + 1] = 'run = ' .. run
        result[#result + 1] = 'desc = ' .. desc
    end
    return result
end

local function sectionName(line)
    return line:match('^%s*%[([^%[].-)%]%s*')
end

local function findArray(lines, start)
    local line = lines[start]
    local open = line:find('%[')
    if not open then
        return nil
    end
    local close = line:find(']', open + 1, true)
    if close then
        return {start, open, start, close}
    end
    for index = start + 1, #lines do
        close = lines[index]:find(']', 1, true)
        if close then
            return {start, open, index, close}
        end
    end
end

local function insertIntoArray(lines, array, rendered)
    local start, open, finish, close = array[1], array[2], array[3], array[4]
    local additions = renderedLines(rendered)
    if #additions == 0 then
        return
    end

    if start == finish then
        local line = lines[start]
        local prefix = line:sub(1, open)
        local body = vim.trim(line:sub(open + 1, close - 1))
        local suffix = line:sub(close)
        local replacement = {prefix}
        vim.list_extend(replacement, additions)
        if body ~= '' then
            replacement[#replacement + 1] = '    ' .. body
        end
        replacement[#replacement + 1] = suffix
        lines[start] = replacement[1]
        insertLines(lines, start + 1, vim.list_slice(replacement, 2))
        return
    end

    insertLines(lines, start + 1, additions)
end

local function decorateKeymap(source, rendered)
    if rendered == '' then
        return source
    end

    local lines = vim.split(source, '\n', {plain = true, trimempty = true})
    local arrayTables
    for index, line in ipairs(lines) do
        if line:match('^%s*%[%[mgr%.prepend_keymap%]%]%s*(#.*)?$') then
            arrayTables = index
            break
        end
    end
    if arrayTables then
        insertLines(lines, arrayTables, arrayTableLines(rendered))
        return table.concat(lines, '\n') .. '\n'
    end

    local inMgr = false
    local mgrIndex
    for index, line in ipairs(lines) do
        local section = sectionName(line)
        if section then
            inMgr = section == 'mgr'
            if inMgr then
                mgrIndex = index
            end
        elseif inMgr then
            local key = line:match('^%s*(prepend_keymap)%s*=') or line:match('^%s*(keymap)%s*=')
            if key then
                local array = findArray(lines, index)
                if array then
                    insertIntoArray(lines, array, rendered)
                    return table.concat(lines, '\n') .. '\n'
                end
            end
        end
    end

    local block = {'prepend_keymap = ['}
    vim.list_extend(block, renderedLines(rendered))
    block[#block + 1] = ']'
    if mgrIndex then
        insertLines(lines, mgrIndex + 1, block)
    else
        local result = {'[mgr]'}
        vim.list_extend(result, block)
        vim.list_extend(result, lines)
        lines = result
    end
    return table.concat(lines, '\n') .. '\n'
end

function M.decorate(source, fixedPath, bindings, openMode)
    local customEntries = customKeymapEntries(bindings, openMode)
    local fixedEntries = fixedKeymapEntries(fixedPath)
    local rendered = customEntries
    if rendered ~= '' and fixedEntries ~= '' then
        rendered = rendered .. '\n' .. fixedEntries
    elseif rendered == '' then
        rendered = fixedEntries
    end
    return decorateKeymap(source, rendered)
end

return M
