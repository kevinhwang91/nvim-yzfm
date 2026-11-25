# nvim-yzfm Yazi adapter

This adapter publishes file actions to the Neovim host through DDS events. Its entry point is synchronous because Yazi's `ps.pub_to` API is available in synchronous plugin contexts. Neovim opens the file in the captured normal window; picker behavior defaults to hiding the float, while a per-key `picker = false` override keeps the still-running floating Yazi process visible.

The fixed profile binds `l`, `<Enter>`, `<C-o>`, `<C-x>`, `<C-v>`, and `<C-t>` to this adapter, and binds `~` synchronously to its embedded view-mode feature. The view-mode layouts are `large` (three columns), `tiny` (two columns), and `small` (one column). `~` cycles `small → tiny → large → small`. Yazi's own `q` mappings remain active in every context. Directory selections use Yazi's normal directory entry action.

## Resize events

While the embedded process is running, Neovim publishes the remote DDS kind `nvim-yzfm-resize` after opening, showing, changing the preset, or resizing the editor. The JSON body is:

```json
{
  "width": 96,
  "height": 32,
  "preset": 3,
  "reason": "preset"
}
```

`reason` is one of `open`, `show`, `preset`, or `window`. A plugin that wants to react to the event subscribes during its synchronous setup:

```lua
function M:setup()
    ps.sub_remote("nvim-yzfm-resize", function(payload)
        -- Apply a layout or emit another Yazi action here.
    end)
end
```

The event is optional. If no plugin subscribes, the publish is discarded silently and the Neovim session continues normally.

## File-operation events

The adapter subscribes to Yazi's built-in `rename`, `bulk-rename`, `move`, `trash`, and `delete` events. It normalizes their paths and publishes them to the Neovim host as the remote `nvim-yzfm-files` event:

```json
{
  "kind": "move",
  "changes": [
    {"from": "/tmp/old.txt", "to": "/tmp/new.txt"}
  ]
}
```

Delete events use a `paths` array instead of `changes`. The Neovim side rebinds clean loaded buffers for rename and move events, and wipes matching clean buffers for trash and delete events. Modified buffers are intentionally left at their old path and available for recovery.
