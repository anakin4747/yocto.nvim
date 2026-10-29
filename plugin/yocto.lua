if vim.g.loaded_yocto then
    return
end
vim.g.loaded_yocto = true

require("yocto").register_defaults()

vim.lsp.handlers["bitbake/EmbeddedLanguageDocs"] = function(...)
    return require("yocto").handler(...)
end

local group = vim.api.nvim_create_augroup("yocto", {})

vim.api.nvim_create_autocmd("FileType", {
    group = group,
    pattern = { "bitbake", "sh", "python" },
    callback = function(event)
        require("yocto").select_server(event.match)
        if event.match == "bitbake" then
            require("yocto").start_proxy(event.buf)
        end
    end,
})

-- No pattern: BufWritePost patterns match file names, not filetypes.
vim.api.nvim_create_autocmd({ "FileType", "BufWritePost" }, {
    group = group,
    callback = function(event)
        if vim.bo[event.buf].filetype == "bitbake" then
            require("yocto.oelint").run(event.buf)
        end
    end,
})

vim.api.nvim_create_autocmd("DiagnosticChanged", {
    group = group,
    callback = function(event)
        require("yocto").sync_diagnostics(event.buf)
    end,
})
