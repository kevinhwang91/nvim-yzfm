# nvim-yzfm

Run Yazi in a floating Neovim window and open selected files in regular
Neovim buffers. The user's Yazi configuration is reused through a temporary
overlay; the original files are never modified.

## Requirements

- Neovim
- `yazi` and `ya` in `PATH`
- No external Lua dependency

## Setup

Load the plugin with your plugin manager and add the mappings you want:

For a native optional package, call `vim.cmd('packadd! nvim-yzfm')` before
`setup()`.

```lua
require('yzfm').setup({
    key_maps = {
        toggle = '<M-o>',
        resize = '<M-i>',
    },
})
```

`require('yzfm').setup()` is enough when mappings are not needed. The
commands `:YaziToggle` and `:YaziResize` are available after setup.

## Everyday behavior

- The first toggle starts at the current file or directory; later toggles
  hide or show the same process.
- Yazi keeps its native `q` behavior.
- Selected files open in the normal Neovim window that launched the session.
  Picker mode hides the float after opening; `picker = false` keeps it visible.
- `nvim .` opens the directory in the floating file manager automatically.
- `l`, `<Enter>`, `<C-o>`, `<C-x>`, `<C-v>`, `<C-t>`, and `~` provide the
  integrated open and view-mode actions.

## Advanced setup

Override only the parts you need:

```lua
require('yzfm').setup({
    yazi = 'yazi',
    ya = 'ya',
    args = {},

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
        ['<C-t>'] = {mode = 'tabedit'},
    },

    floating_window = {
        presets = {
            {width = 0.60, height = 0.60},
            {width = 0.80, height = 0.80},
            {width = 0.86, height = 0.86},
            {width = 0.95, height = 0.95},
        },
        preset = 3,
        border = 'single',
        border_highlight = 'YzfmBorder',
        title = nil,
        title_pos = 'center',
        shadow = 70,
    },

    viewmode = {
        large = {ratio = {5, 8, 12}, min_width = 90},
        tiny = {ratio = {1, 1, 0}, min_width = 50, max_width = 89},
        small = {ratio = {0, 1, 0}, max_width = 49},
    },
})
```

Modes are `edit`, `split`, `vsplit`, and `tabedit`. Picker defaults to `true`;
set `picker = false` to keep the floating session visible. `preset` is a
one-based index into `floating_window.presets`; `shadow` accepts `false` or a
blend value from `0` to `100`. `~` cycles `small → tiny → large`.

The floating window uses `YzfmNormal` and `YzfmBorder` highlights:

```lua
vim.api.nvim_set_hl(0, 'YzfmNormal', {link = 'CursorLine'})
vim.api.nvim_set_hl(0, 'YzfmBorder', {fg = '#e5c07b'})
```

## Existing Yazi configuration

Decoration is always enabled for the floating session. The overlay decorates
the user's `keymap.toml` and `init.lua`, reuses other configuration files, and
leaves the parent `YAZI_CONFIG_HOME` unchanged. Existing openers, previews,
themes, plugins, and drag-and-drop rules continue to work. Normal Yazi
sessions are unaffected.

Rename, bulk-rename, move, trash, and delete events update clean loaded
Neovim buffers. Modified buffers remain at their old path and are reported
instead of being overwritten silently.
