local api = vim.api

local M = {}

local module_file = debug.getinfo(1, "S").source:sub(2)
local plugin_root = vim.fn.fnamemodify(module_file, ":h:h:h")
local fixed_yazi_config = plugin_root .. "/yazi"
local effective_yazi_config = vim.fn.stdpath("cache") .. "/nvim-yzfm/yazi"

M.OPEN_MODE = {
  edit = "edit",
  split = "split",
  vsplit = "vsplit",
  tabedit = "tabedit",
}

local function default_yazi_config_home()
  local configured = vim.env.YAZI_CONFIG_HOME
  if configured and configured ~= "" and configured:sub(1, 1) == "/" then
    return vim.fn.fnamemodify(configured, ":p")
  end

  local xdg = vim.env.XDG_CONFIG_HOME
  if xdg and xdg ~= "" and xdg:sub(1, 1) == "/" then
    return vim.fn.fnamemodify(xdg .. "/yazi", ":p")
  end
  return vim.fn.expand("~/.config/yazi")
end

local defaults = {
  yazi = "yazi",
  ya = "ya",
  args = {},
  floating_window = {
    width = 0.86,
    height = 0.86,
    border = "rounded",
    title = " Yazi ",
    title_pos = "center",
  },
  open_commands = {
    edit = "drop",
    split = "split",
    vsplit = "vsplit",
    tabedit = "tabedit",
  },
  reveal_current = true,
  sync_cwd = true,
  keybindings = {
    ["<C-o>"] = { mode = "edit", submit = true },
    ["<C-x>"] = { mode = "split", submit = true },
    ["<C-v>"] = { mode = "vsplit", submit = true },
    ["<C-t>"] = { mode = "tabedit", submit = true },
  },
  keymaps = {},
}

local state = {
  config = nil,
  buf = nil,
  win = nil,
  yazi_job = nil,
  client_id = nil,
  chooser_file = nil,
  cwd_file = nil,
  origin_win = nil,
  origin_tab = nil,
  next_open_mode = nil,
  generation = 0,
}

local function notify(message, level)
  vim.schedule(function()
    vim.notify(message, level or vim.log.levels.INFO, { title = "nvim-yzfm" })
  end)
end

local function valid_buf(buf)
  return buf and api.nvim_buf_is_valid(buf)
end

local function valid_win(win)
  return win and api.nvim_win_is_valid(win)
end

local function job_running(job)
  return job and vim.fn.jobwait({ job }, 0)[1] == -1
end

local function path_join(parent, child)
  if parent:sub(-1) == "/" then
    return parent .. child
  end
  return parent .. "/" .. child
end

local function absolute_path(path)
  if type(path) ~= "string" or path == "" then
    return nil
  end
  return vim.fn.fnamemodify(vim.fn.expand(path), ":p")
end

local function normalized_path(path)
  local absolute = absolute_path(path)
  if not absolute then
    return nil
  end
  if absolute:sub(-1) == "/" and #absolute > 1 then
    absolute = absolute:sub(1, -2)
  end
  return absolute
end

local function apply_cwd(path)
  local target = normalized_path(path)
  if not target or vim.fn.isdirectory(target) ~= 1 then
    return
  end

  local ok, error_message = pcall(function()
    vim.cmd({
      cmd = "cd",
      args = { target },
      mods = { silent = true, noautocmd = true },
    })
  end)
  if not ok then
    notify(error_message, vim.log.levels.ERROR)
  end
end

local function emit_to(receiver, action, argument)
  if not receiver then
    return
  end
  local command = { state.config.ya, "emit-to", tostring(receiver), action }
  if argument then
    command[#command + 1] = argument
  end
  vim.fn.jobstart(command, { detach = true, stdin = "null" })
end

local function normal_window(preferred, tabpage)
  local function is_normal(win)
    if not valid_win(win) then
      return false
    end
    return api.nvim_win_get_config(win).relative == ""
  end

  if is_normal(preferred) then
    return preferred
  end

  if tabpage and api.nvim_tabpage_is_valid(tabpage) then
    for _, win in ipairs(api.nvim_tabpage_list_wins(tabpage)) do
      if is_normal(win) then
        return win
      end
    end
  end

  for _, win in ipairs(api.nvim_list_wins()) do
    if is_normal(win) then
      return win
    end
  end
end

local function restore_origin(tabpage, win)
  if tabpage and api.nvim_tabpage_is_valid(tabpage) then
    pcall(api.nvim_set_current_tabpage, tabpage)
  end
  local target = normal_window(win, tabpage)
  if target then
    pcall(api.nvim_set_current_win, target)
  end
end

local function capture_origin()
  local tabpage = api.nvim_get_current_tabpage()
  local win = normal_window(api.nvim_get_current_win(), tabpage)
  state.origin_tab = tabpage
  state.origin_win = win or api.nvim_get_current_win()
end

local function resolve_dimension(value, total, minimum)
  if type(value) ~= "number" then
    return total
  end
  local result = value > 0 and value < 1 and math.floor(total * value) or math.floor(value)
  return math.max(minimum, math.min(total, result))
end

local function window_config()
  local opts = state.config.floating_window
  local width = resolve_dimension(opts.width, math.max(vim.o.columns - 2, 1), 1)
  local height = resolve_dimension(opts.height, math.max(vim.o.lines - 2, 1), 1)
  local config = {
    relative = "editor",
    width = width,
    height = height,
    row = math.max(0, math.floor((vim.o.lines - height) / 2 - 1)),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    style = "minimal",
    border = opts.border,
  }

  if opts.title then
    config.title = opts.title
    config.title_pos = opts.title_pos or "center"
  end
  return config
end

local function resize_window()
  if valid_win(state.win) then
    api.nvim_win_set_config(state.win, window_config())
  end
end

local function current_entry()
  if not state.config.reveal_current then
    return nil
  end

  local path = vim.fn.expand("%:p")
  if path == "" then
    return nil
  end
  if vim.fn.filereadable(path) ~= 1 and vim.fn.isdirectory(path) ~= 1 then
    return nil
  end
  return path
end

local function uv_lstat(path)
  local uv = vim.uv or vim.loop
  return uv and uv.fs_lstat(path) or nil
end

local function path_exists(path)
  return uv_lstat(path) ~= nil
end

local function mkdir(path)
  if vim.fn.isdirectory(path) == 1 then
    return true
  end
  return vim.fn.mkdir(path, "p") == 1
end

local function unlink(path)
  if not path_exists(path) then
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
  if path_exists(target) then
    return true
  end
  local uv = vim.uv or vim.loop
  if not uv or not uv.fs_symlink then
    return false, "Neovim does not provide a symlink API"
  end
  local ok, result, error_message = pcall(uv.fs_symlink, source, target)
  if not ok or not result then
    return false, error_message or tostring(result)
  end
  return true
end

local function fixed_keymap_entries()
  local path = path_join(fixed_yazi_config, "keymap.toml")
  if vim.fn.filereadable(path) ~= 1 then
    return ""
  end

  local lines = vim.fn.readfile(path)
  local result = {}
  local inside = false
  for _, line in ipairs(lines) do
    if not inside and line:match("^%s*prepend_keymap%s*=%s*%[%s*$") then
      inside = true
    elseif inside and line:match("^%s*%]%s*,?%s*$") then
      break
    elseif inside then
      result[#result + 1] = line
    end
  end
  return table.concat(result, "\n")
end

local function decorate_keymap(source, rendered)
  if rendered == "" then
    return source
  end

  local table_start = source:find("%[%[mgr%.prepend_keymap%]%]")
  if table_start then
    return source:sub(1, table_start - 1) .. rendered .. "\n" .. source:sub(table_start)
  end

  local _, array_end = source:find("prepend_keymap%s*=%s*%[")
  if array_end then
    local line_end = source:find("\n", array_end, true)
    if not line_end then
      line_end = #source + 1
    end
    return source:sub(1, line_end) .. rendered .. "\n" .. source:sub(line_end + 1)
  end

  local _, keymap_end = source:find("keymap%s*=%s*%[")
  if keymap_end then
    local line_end = source:find("\n", keymap_end, true)
    if not line_end then
      line_end = #source + 1
    end
    return source:sub(1, line_end) .. rendered .. "\n" .. source:sub(line_end + 1)
  end

  local mgr_start, mgr_end = source:find("%[mgr%]%s*\n")
  local block = "prepend_keymap = [\n" .. rendered .. "\n]\n"
  if mgr_start then
    return source:sub(1, mgr_end) .. block .. source:sub(mgr_end + 1)
  end
  return "[mgr]\n" .. block .. "\n" .. source
end

local function config_home()
  local base = absolute_path(default_yazi_config_home())
  local home = absolute_path(effective_yazi_config)
  return base, home
end

local function ensure_yazi_config()
  local base, home = config_home()
  if not home then
    return nil
  end
  if not base or base == home then
    return home
  end
  if not mkdir(home) then
    notify("Could not create Yazi config overlay: " .. home, vim.log.levels.WARN)
    return base
  end

  if vim.fn.isdirectory(base) == 1 then
    for _, name in ipairs(vim.fn.readdir(base)) do
      if name ~= "keymap.toml" then
        local source = path_join(base, name)
        local target = path_join(home, name)
        if not path_exists(target) then
          local ok, error_message = symlink(source, target)
          if not ok then
            notify("Could not link Yazi config " .. name .. ": " .. tostring(error_message), vim.log.levels.WARN)
          end
        end
      end
    end
  end

  local keymap_target = path_join(home, "keymap.toml")
  local keymap_source = path_join(base, "keymap.toml")
  local source = ""
  if vim.fn.filereadable(keymap_source) == 1 then
    source = table.concat(vim.fn.readfile(keymap_source), "\n") .. "\n"
  end
  local decorated = "# Generated by nvim-yzfm from the plugin's fixed Yazi profile.\n" .. decorate_keymap(source, fixed_keymap_entries())
  local existing = uv_lstat(keymap_target)
  if existing and existing.type == "link" then
    unlink(keymap_target)
  elseif existing and vim.fn.filereadable(keymap_target) == 1 then
    local current = table.concat(vim.fn.readfile(keymap_target), "\n")
    if not current:match("^# Generated by nvim%-yzfm") then
      notify("Keeping existing Yazi overlay keymap: " .. keymap_target, vim.log.levels.WARN)
      return home
    end
  end
  vim.fn.writefile(vim.split(decorated, "\n", { plain = true }), keymap_target)

  return home
end

local function build_yazi_command(opts)
  local config_home = ensure_yazi_config()
  state.client_id = string.format("%.0f", vim.fn.localtime() * 1000000 + vim.fn.getpid() + state.generation)
  state.chooser_file = vim.fn.tempname()
  state.cwd_file = vim.fn.tempname()

  local command = {
    state.config.yazi,
    "--chooser-file",
    state.chooser_file,
    "--cwd-file",
    state.cwd_file,
    "--client-id",
    state.client_id,
  }
  for _, arg in ipairs(state.config.args) do
    command[#command + 1] = arg
  end
  for _, arg in ipairs(opts.args or {}) do
    command[#command + 1] = arg
  end

  local entry = opts.path or current_entry()
  if entry then
    command[#command + 1] = entry
  end
  return command, config_home
end

local function ensure_buffer()
  if valid_buf(state.buf) then
    return state.buf
  end

  state.buf = api.nvim_create_buf(false, true)
  local buffer = state.buf
  vim.bo[buffer].bufhidden = "hide"
  vim.bo[buffer].buflisted = false
  vim.bo[buffer].swapfile = false
  vim.bo[buffer].filetype = "yazi"
  api.nvim_create_autocmd("BufWipeout", {
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

local function show_window()
  if not valid_buf(state.buf) then
    return false
  end
  if valid_win(state.win) then
    api.nvim_set_current_win(state.win)
    return true
  end

  state.win = api.nvim_open_win(state.buf, true, window_config())
  vim.wo[state.win].winblend = 0
  return true
end

local function close_window()
  local win = state.win
  state.win = nil
  if valid_win(win) then
    pcall(api.nvim_win_close, win, true)
  end
end

local function cleanup_files()
  if state.chooser_file then
    vim.fn.delete(state.chooser_file)
  end
  if state.cwd_file then
    vim.fn.delete(state.cwd_file)
  end
  state.chooser_file = nil
  state.cwd_file = nil
end

local function teardown(stop_job)
  local job = state.yazi_job
  state.yazi_job = nil
  state.client_id = nil
  state.generation = state.generation + 1
  close_window()
  local buf = state.buf
  state.buf = nil
  if valid_buf(buf) then
    pcall(api.nvim_buf_delete, buf, { force = true })
  end
  cleanup_files()
  if stop_job and job and job_running(job) then
    vim.fn.jobstop(job)
  end
end

local function selected_paths(path)
  if not path or vim.fn.filereadable(path) ~= 1 then
    return {}
  end
  local paths = {}
  for _, value in ipairs(vim.fn.readfile(path)) do
    if value ~= "" then
      paths[#paths + 1] = value
    end
  end
  return paths
end

local function get_edit_command(open_mode)
  local mode = M.OPEN_MODE[open_mode] and open_mode or "edit"
  return state.config.open_commands[mode] or state.config.open_commands.edit, mode
end

local function open_paths(paths, open_mode, origin_tab, origin_win)
  if #paths == 0 then
    return
  end

  if origin_tab and api.nvim_tabpage_is_valid(origin_tab) then
    pcall(api.nvim_set_current_tabpage, origin_tab)
  end
  local target_win = normal_window(origin_win, origin_tab)
  if target_win then
    pcall(api.nvim_set_current_win, target_win)
  end

  local command = get_edit_command(open_mode)
  local ok, error_message = pcall(function()
    vim.cmd({ cmd = command, args = { paths[1] }, mods = { silent = true } })
    for index = 2, #paths do
      vim.cmd({ cmd = "badd", args = { paths[index] }, mods = { silent = true } })
    end
  end)
  if not ok then
    notify(error_message, vim.log.levels.ERROR)
  end
end

local function finish(generation)
  if generation ~= state.generation then
    return
  end

  local selected = selected_paths(state.chooser_file)
  local cwd_paths = selected_paths(state.cwd_file)
  local cwd = cwd_paths[1]
  local origin_tab = state.origin_tab
  local origin_win = state.origin_win
  local open_mode = state.next_open_mode

  teardown(false)
  restore_origin(origin_tab, origin_win)
  open_paths(selected, open_mode, origin_tab, origin_win)
  if state.config.sync_cwd and cwd then
    apply_cwd(cwd)
  end
  state.origin_tab = nil
  state.origin_win = nil
  state.next_open_mode = nil
end

local function set_terminal_keybindings(buffer)
  for key, value in pairs(state.config.keybindings or {}) do
    local mode = value
    local submit = false
    if type(value) == "table" then
      mode = value.mode
      submit = value.submit == true
    end
    if M.OPEN_MODE[mode] then
      vim.keymap.set("t", key, function()
        M.set_next_open_mode(mode)
        if submit and state.yazi_job then
          vim.schedule(function()
            if job_running(state.yazi_job) then
              vim.fn.chansend(state.yazi_job, "\r")
            end
          end)
        end
      end, { buffer = buffer, silent = true, nowait = true, desc = "Yazi: " .. mode })
    end
  end
end

local function start_yazi(opts)
  state.generation = state.generation + 1
  local generation = state.generation
  state.next_open_mode = opts.open_mode
  capture_origin()
  ensure_buffer()
  show_window()

  local command, config_home = build_yazi_command(opts)
  local job = vim.fn.termopen(command, {
    cwd = opts.cwd or vim.fn.getcwd(),
    env = config_home and { YAZI_CONFIG_HOME = config_home } or nil,
    on_exit = function(job_id)
      if generation == state.generation and (state.yazi_job == nil or state.yazi_job == job_id) then
        state.yazi_job = job_id
        vim.schedule(function()
          finish(generation)
        end)
      end
    end,
  })
  if job <= 0 then
    teardown(false)
    notify("Could not start Yazi", vim.log.levels.ERROR)
    return false
  end

  state.yazi_job = job
  set_terminal_keybindings(state.buf)
  vim.cmd.startinsert()
  return true
end

local function active()
  return job_running(state.yazi_job) and valid_buf(state.buf)
end

function M.setup(user_opts)
  state.config = vim.tbl_deep_extend("force", {}, defaults, user_opts or {})
  ensure_yazi_config()

  local group = api.nvim_create_augroup("nvim-yzfm", { clear = true })
  api.nvim_create_autocmd("VimResized", {
    group = group,
    callback = resize_window,
  })

  api.nvim_create_user_command("Yazi", function(command)
    if command.args ~= "" and active() then
      M.reveal(command.args)
    else
      M.open(command.args ~= "" and command.args or nil)
    end
  end, { nargs = "?", complete = "file", force = true })
  api.nvim_create_user_command("YaziToggle", function()
    M.toggle()
  end, { force = true })
  api.nvim_create_user_command("YaziResize", function()
    resize_window()
  end, { force = true })
  api.nvim_create_user_command("YaziReveal", function()
    M.reveal()
  end, { force = true })
  api.nvim_create_user_command("YaziQuit", function()
    teardown(true)
    state.origin_tab = nil
    state.origin_win = nil
    state.next_open_mode = nil
  end, { force = true })
  api.nvim_create_user_command("YaziSplit", function()
    M.open(nil, M.OPEN_MODE.split)
  end, { force = true })
  api.nvim_create_user_command("YaziVsplit", function()
    M.open(nil, M.OPEN_MODE.vsplit)
  end, { force = true })
  api.nvim_create_user_command("YaziTabedit", function()
    M.open(nil, M.OPEN_MODE.tabedit)
  end, { force = true })
  api.nvim_create_user_command("YaziConfig", function()
    local _, home = config_home()
    vim.notify(home, vim.log.levels.INFO, { title = "nvim-yzfm Yazi config" })
  end, { force = true })

  local maps = state.config.keymaps
  if maps.toggle then
    vim.keymap.set("n", maps.toggle, "<Cmd>YaziToggle<CR>", { silent = true, desc = "Toggle Yazi" })
    vim.keymap.set("t", maps.toggle, "<C-\\><C-n><Cmd>YaziToggle<CR>", { silent = true, desc = "Toggle Yazi" })
  end
  if maps.resize then
    vim.keymap.set({ "n", "t" }, maps.resize, "<Cmd>YaziResize<CR>", { silent = true, desc = "Resize Yazi" })
  end

  return M
end

function M.is_configured()
  return state.config ~= nil
end

function M.open(path, open_mode)
  if state.config == nil then
    M.setup()
  end
  if active() then
    if open_mode then
      M.set_next_open_mode(open_mode)
    end
    if path then
      M.reveal(path)
    elseif not valid_win(state.win) then
      show_window()
    end
    return
  end
  if state.yazi_job then
    teardown(true)
  end
  start_yazi({ path = path, open_mode = open_mode })
end

function M.toggle(opts)
  if active() then
    if valid_win(state.win) then
      close_window()
      restore_origin(state.origin_tab, state.origin_win)
    else
      show_window()
    end
    return
  end
  M.open(opts and opts.path or nil, opts and opts.open_mode or nil)
end

function M.hide()
  if active() then
    close_window()
    restore_origin(state.origin_tab, state.origin_win)
  end
end

function M.show()
  if active() then
    show_window()
  else
    M.open()
  end
end

function M.resize()
  resize_window()
end

function M.reveal(path)
  if not active() then
    M.open(path)
    return
  end
  local target = path or vim.fn.expand("%:p")
  if target == "" then
    target = vim.fn.getcwd()
  end
  emit_to(state.client_id, "reveal", target)
end

function M.set_next_open_mode(open_mode)
  if open_mode ~= nil and not M.OPEN_MODE[open_mode] then
    notify("Unknown Yazi open mode: " .. tostring(open_mode), vim.log.levels.WARN)
    return
  end
  state.next_open_mode = open_mode
end

return M
