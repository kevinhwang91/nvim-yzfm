return vim.schedule_wrap(function(message, level)
    vim.notify(message, level or vim.log.levels.INFO, {title = 'nvim-yzfm'})
end)
