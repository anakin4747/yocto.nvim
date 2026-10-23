-- Entry point for yocto

if vim.g.loaded_yocto then
    return
end
vim.g.loaded_yocto = true

require("yocto").register_defaults()

vim.lsp.handlers["bitbake/EmbeddedLanguageDocs"] = function(...)
    return require("yocto").handler(...)
end

vim.api.nvim_create_autocmd("FileType", {
    group = vim.api.nvim_create_augroup("yocto", {}),
    pattern = { "bitbake", "sh", "python" },
    callback = function(ev)
        require("yocto").select_server(ev.match)
    end,
})
