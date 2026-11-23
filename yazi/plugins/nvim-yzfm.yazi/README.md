# nvim-yzfm Yazi adapter

This adapter publishes the hovered or selected paths to the Neovim host through DDS. Its entry point is synchronous because Yazi's `ps.pub_to` API is available in synchronous plugin contexts.

Bind the adapter from `keymap.toml` with `plugin --mode=sync nvim-yzfm -- edit`, `split`, `vsplit`, or `tabedit`. The supplied `l` and `<Enter>` mappings enter directories in Yazi and send files to the normal Neovim buffer. The `jump-cwd` action follows Neovim's current directory, while `emit-cwd` sets Neovim's global directory to the active Yazi directory.
