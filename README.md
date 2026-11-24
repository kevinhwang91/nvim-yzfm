# nvim-yzfm

An embedded Yazi terminal for Neovim. It captures the normal window that launched the file manager, opens Yazi in a floating terminal, and returns selected paths to that original window.

The fixed profile routes `l`, `<Enter>`, and the four open-mode keys through the plugin's small Yazi adapter. Selected files are opened in a normal Neovim window; picker behavior hides the floating process by default, while a binding with `picker = false` keeps it visible.

The embedded profile leaves Yazi's `q` behavior unchanged. Preview and manager contexts therefore keep their own `q` mappings.

When Neovim is started with one directory argument, such as `nvim .`, the directory is opened automatically in the floating Yazi process and its temporary startup buffer is removed from the buffer list. A file argument or multiple arguments keep Neovim's normal startup behavior.

## Setup

```lua
vim.cmd('packadd! nvim-yzfm')

require('yzfm').setup({
    yazi = 'yazi',
    ya = 'ya',
    args = {},

    floating_window = {
        presets = {
            {width = 0.60, height = 0.60},
            {width = 0.80, height = 0.80},
            {width = 0.86, height = 0.86},
            {width = 0.95, height = 0.95},
        },
        preset = 3,
        border = 'single',
        border_highlight = 'YaziBorder',
        title = nil,
        title_pos = 'center',
        shadow = 70,
    },
    key_maps = {
        toggle = '<M-o>',
        resize = '<M-i>',
    },
    key_bindings = {
        ['l'] = {mode = 'edit', picker = false},
        ['<Enter>'] = {mode = 'edit', picker = false},
        ['<C-o>'] = {mode = 'edit'},
        ['<C-x>'] = {mode = 'split'},
        ['<C-v>'] = {mode = 'vsplit'},
        ['<C-t>'] = {mode = 'tabedit', picker = false},
    },
})
```

`key_bindings` are written directly into the generated Yazi keymap. Each mapping records its open mode and sends the selected paths back to Neovim without a terminal-buffer mapping layer. Picker behavior defaults to `true`: the selected file opens in a normal Neovim window and the floating Yazi window is hidden. Set `picker = false` on a binding to keep the floating window visible. The same modes are also available through `:YaziSplit`, `:YaziVsplit`, and `:YaziTabedit`.

Configuration keys use snake_case to match Neovim's native option names where applicable: `floating_window`, `key_maps`, and `key_bindings`.

The floating window uses `floating_window.preset` as a one-based index into `floating_window.presets`; the default `3` selects the 86% layout. It has a simple single-line border, no title, and a 70% shadow by default. Set `floating_window.shadow = false` to disable the shadow, or use a number from `0` to `100` to adjust its blend.

The terminal window uses the `YaziNormal` highlight group. It defaults to `NormalFloat`, and can be relinked with `vim.api.nvim_set_hl(0, 'YaziNormal', {link = 'CursorLine'})`.

The border uses `YaziBorder` through the `FloatBorder` window highlight. It defaults to `FloatBorder`; set a color without changing other floating windows with `vim.api.nvim_set_hl(0, 'YaziBorder', {fg = '#e5c07b'})`.

`:YaziToggle` starts Yazi on the current buffer's file (or directory), then hides or shows the same running process. Yazi handles `q` according to its active context.

The fixed open modes are `edit` (`:drop`), `split`, `vsplit`, and `tabedit`. The first selected path is opened in the captured normal window; additional paths are loaded with `:badd`. Paths are passed as argv items and remain safe when they contain spaces or commas.

## Decorating the existing Yazi configuration

The decoration is always enabled and is not a setup option. The fixed profile lives in the plugin's [`yazi/keymap.toml`](/home/kevin/.local/share/nvim/site/pack/core/opt/nvim-yzfm/yazi/keymap.toml). The child process receives `YAZI_CONFIG_HOME` pointing to the generated overlay under Neovim's cache directory.

The original configuration is taken from `$YAZI_CONFIG_HOME`, `$XDG_CONFIG_HOME/yazi`, or `~/.config/yazi`. Every file except `keymap.toml` is symlinked into the overlay, so opener rules, previews, themes, plugins, flavors, and drag-and-drop settings remain unchanged. The fixed profile keymap is prepended to the original keymap on every launch.

The parent process's `YAZI_CONFIG_HOME` is not changed.

This means an existing Yazi setup can stay untouched. Preview mappings and interactive open-with mappings continue to be used by the embedded process. The fixed `l`/`<Enter>` mappings use the default picker behavior unless they are added to `key_bindings` with `picker = false`; an interactive opener remains an external opener. When picker mode hides the float, toggling Yazi again reopens the same process at its current position.

## Commands and lifecycle

The plugin defines `:YaziToggle`, `:YaziResize`, `:YaziSplit`, `:YaziVsplit`, and `:YaziTabedit`.

`:YaziToggle` hides or shows the same running process. When Yazi exits, the float is closed and the original tab/window is restored before selected files are opened.

`:YaziResize` and the configured resize key cycle the built-in 60%, 80%, 86%, and 95% layouts. A terminal/editor resize recalculates the current layout without changing the selected preset.

No external Lua dependency is required.

## Code layout

- `init.lua` exposes the Lua API and registers Neovim commands and mappings.
- `session.lua` manages the Yazi process and selection lifecycle. `dds.lua` handles communication with `ya`.
- `window.lua` owns the floating terminal, shadow, and layout. `files.lua` resolves paths and opens them in Neovim.
- `config.lua` generates the embedded Yazi configuration. `keymap.lua` renders the decorated keymap.
- `startup.lua` handles a directory passed to Neovim at startup.
