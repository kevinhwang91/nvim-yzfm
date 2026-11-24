# nvim-yzfm

An embedded Yazi terminal for Neovim. It captures the normal window that launched the file manager, opens Yazi in a floating terminal, and returns selected paths to that original window.

The fixed profile routes `l`, `<Enter>`, and the four open-mode keys through the plugin's small Yazi adapter. Selected files are opened in a normal Neovim window; picker behavior hides the floating process by default, while a binding with `picker = false` keeps it visible.

The embedded profile maps `q` to exit Yazi without saving a resume state. A later toggle starts from the current Neovim buffer exactly like the first toggle.

When Neovim is started with one directory argument, such as `nvim .`, the directory is opened automatically in the floating Yazi process and its temporary startup buffer is removed from the buffer list. A file argument or multiple arguments keep Neovim's normal startup behavior.

## Setup

```lua
vim.cmd('packadd! nvim-yzfm')

require('nvim-yzfm').setup({
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
        title = nil,
        titlePos = 'center',
        shadow = 70,
    },
    keyMaps = {
        toggle = '<M-o>',
        resize = '<M-i>',
    },
    keyBindings = {
        ['l'] = {mode = 'edit', picker = false},
        ['<Enter>'] = {mode = 'edit', picker = false},
        ['<C-o>'] = {mode = 'edit'},
        ['<C-x>'] = {mode = 'split'},
        ['<C-v>'] = {mode = 'vsplit'},
        ['<C-t>'] = {mode = 'tabedit', picker = false},
    },
})
```

`keyBindings` are Neovim terminal-buffer mappings. Each mapping records its open mode and always forwards the key to the fixed Yazi profile, so the action is triggered immediately. Picker behavior defaults to `true`: the selected file opens in a normal Neovim window and the floating Yazi window is hidden. Set `picker = false` on a binding to keep the floating window visible. The same modes are also available through `:Yazi`, `:YaziSplit`, `:YaziVsplit`, and `:YaziTabedit`.

Configuration keys use camelCase: `floatingWindow`, `keyMaps`, and `keyBindings`.

The floating window uses `floatingWindow.preset` as a one-based index into `floatingWindow.presets`; the default `3` selects the 86% layout. It has a simple single-line border, no title, and a 70% shadow by default. Set `floatingWindow.shadow = false` to disable the shadow, or use a number from `0` to `100` to adjust its blend.

The terminal window uses the `YaziNormal` highlight group. It defaults to `NormalFloat`, and can be relinked with `vim.api.nvim_set_hl(0, 'YaziNormal', {link = 'CursorLine'})`.

The border uses `YaziBorder` through the `FloatBorder` window highlight. It defaults to `FloatBorder`; set a color without changing other floating windows with `vim.api.nvim_set_hl(0, 'YaziBorder', {fg = '#e5c07b'})`.

`:Yazi` starts a new process in the current Neovim buffer's directory. `:YaziToggle` hides or shows the same running process; when no process is active, it starts on the current buffer's file (or directory). Pressing `q` exits without saving Yazi state, so the next toggle follows the same current-buffer startup path.

The fixed open modes are `edit` (`:drop`), `split`, `vsplit`, and `tabedit`. The first selected path is opened in the captured normal window; additional paths are loaded with `:badd`. Paths are passed as argv items and remain safe when they contain spaces or commas.

## Decorating the existing Yazi configuration

The decoration is always enabled and is not a setup option. The fixed profile lives in the plugin's [`yazi/keymap.toml`](/home/kevin/.local/share/nvim/site/pack/core/opt/nvim-yzfm/yazi/keymap.toml). The child process receives `YAZI_CONFIG_HOME` pointing to the generated overlay under Neovim's cache directory.

The original configuration is taken from `$YAZI_CONFIG_HOME`, `$XDG_CONFIG_HOME/yazi`, or `~/.config/yazi`. Every file except `keymap.toml` is symlinked into the overlay, so opener rules, previews, themes, plugins, flavors, and drag-and-drop settings remain unchanged. The fixed profile keymap is prepended to the original keymap on every launch. `:YaziConfig` prints the effective overlay directory.

The parent process's `YAZI_CONFIG_HOME` is not changed.

This means an existing Yazi setup can stay untouched. Preview mappings and interactive open-with mappings continue to be used by the embedded process. The fixed `l`/`<Enter>` mappings use the default picker behavior unless they are added to `keyBindings` with `picker = false`; an interactive opener remains an external opener. When picker mode hides the float, toggling Yazi again reopens the same process at its current position.

## Commands and lifecycle

The plugin defines `:Yazi`, `:YaziToggle`, `:YaziResize`, `:YaziReveal`, `:YaziSplit`, `:YaziVsplit`, `:YaziTabedit`, and `:YaziConfig`.

`:YaziToggle` hides or shows the same running process. After `q` exits Yazi, the next toggle starts a new process from the current buffer. When Yazi exits, the float is closed and the original tab/window is restored before selected files are opened.

`:YaziResize` and the configured resize key cycle the built-in 60%, 80%, 86%, and 95% layouts. A terminal/editor resize recalculates the current layout without changing the selected preset.

No external Lua dependency is required.
