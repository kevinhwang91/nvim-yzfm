# nvim-yzfm

An embedded Yazi terminal for Neovim. It captures the normal window that launched the file manager, opens Yazi in a floating terminal, and returns selected paths to that original window.

The integration uses Yazi's `--chooser-file` and `--cwd-file` options. A normal open action writes the selected paths and exits Yazi; cancelling simply returns to Neovim. No Yazi-side RPC subscriber or required Yazi plugin is involved.

## Setup

```lua
require("nvim-yzfm").setup({
  keymaps = {
    toggle = "<M-o>",
    resize = "<M-i>",
  },
  keybindings = {
    ["<C-o>"] = { mode = "edit", submit = true },
    ["<C-x>"] = { mode = "split", submit = true },
    ["<C-v>"] = { mode = "vsplit", submit = true },
    ["<C-t>"] = { mode = "tabedit", submit = true },
  },
})
```

`keybindings` are Neovim terminal-buffer mappings, not Yazi mappings. `submit = true` sends Enter after changing the next open mode; omit it when you want to select the mode and press Enter yourself. The same modes are also available through `:Yazi`, `:YaziSplit`, `:YaziVsplit`, and `:YaziTabedit`.

The default open commands are `edit = "drop"`, `split = "split"`, `vsplit = "vsplit"`, and `tabedit = "tabedit"`. The first selected path is opened in the captured normal window; additional paths are loaded with `:badd`. Paths are passed as argv items and remain safe when they contain spaces or commas.

## Decorating the existing Yazi configuration

The decoration is always enabled and is not a setup option. The fixed profile lives in the plugin's [`yazi/keymap.toml`](/home/kevin/.local/share/nvim/site/pack/core/opt/nvim-yzfm/yazi/keymap.toml). The child process receives `YAZI_CONFIG_HOME` pointing to the generated overlay under Neovim's cache directory.

The original configuration is taken from `$YAZI_CONFIG_HOME`, `$XDG_CONFIG_HOME/yazi`, or `~/.config/yazi`. Every file except `keymap.toml` is symlinked into the overlay, so opener rules, previews, themes, plugins, flavors, and drag-and-drop settings remain unchanged. The fixed profile keymap is prepended to the original keymap on every launch. `:YaziConfig` prints the effective overlay directory.

The parent process's `YAZI_CONFIG_HOME` is not changed.

This means an existing Yazi setup can stay untouched. In particular, existing `l`/`<Enter>` mappings, preview mappings, and interactive open-with mappings continue to be used by the embedded process. The chooser flag only affects non-interactive file opens; an interactive opener remains an external opener.

## Commands and lifecycle

The plugin defines `:Yazi`, `:YaziToggle`, `:YaziResize`, `:YaziReveal`, `:YaziQuit`, `:YaziSplit`, `:YaziVsplit`, `:YaziTabedit`, and `:YaziConfig`.

`:YaziToggle` hides or shows the same running process. When Yazi exits, the float is closed and the original tab/window is restored before selected files are opened. `--cwd-file` can update Neovim's global working directory; disable this with `sync_cwd = false`.

No external Lua dependency is required.
