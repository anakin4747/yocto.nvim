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
    callback = function(ev)
        require("yocto").select_server(ev.match)
        if ev.match == "bitbake" then
            require("yocto").start_proxy(ev.buf)
        end
    end,
})

-- No pattern: BufWritePost patterns match file names, not filetypes.
vim.api.nvim_create_autocmd({ "FileType", "BufWritePost" }, {
    group = group,
    callback = function(ev)
        if vim.bo[ev.buf].filetype == "bitbake" then
            require("yocto.oelint").run(ev.buf, { force = true })
        end
    end,
})

vim.api.nvim_create_autocmd("DiagnosticChanged", {
    group = group,
    callback = function(ev)
        require("yocto").sync_diagnostics(ev.buf)
    end,
})
