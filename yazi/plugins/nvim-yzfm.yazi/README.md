# nvim-yzfm Yazi adapter

This adapter publishes file actions to the Neovim host through DDS events. Its entry point is synchronous because Yazi's `ps.pub_to` API is available in synchronous plugin contexts. Neovim opens the file in the captured normal window; picker behavior defaults to hiding the float, while a per-key `picker = false` override keeps the still-running floating Yazi process visible.

The fixed profile binds `q`, `l`, `<Enter>`, `<C-o>`, `<C-x>`, `<C-v>`, and `<C-t>` to this adapter. `q` exits Yazi without sending state to Neovim. The next toggle starts from the current Neovim buffer. Directory selections use Yazi's normal directory entry action.
