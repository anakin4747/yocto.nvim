-- Handles the bitbake/EmbeddedLanguageDocs notification from
-- bitbake-language-server by writing embedded bash/python docs to disk.

local M = {}

local EXTENSIONS = { bash = ".sh", python = ".py" }

local storage_dir = vim.fs.joinpath(vim.fn.stdpath("cache"), "yocto", "embedded-documents")
local infos = {} -- embedded_uri -> { original_uri, language, character_indexes }

function M.setup(opts)
    opts = opts or {}
    if opts.storage_dir then
        storage_dir = opts.storage_dir
    end
end

function M._reset()
    infos = {}
end

local function path_for(original_uri, language)
    return vim.fs.joinpath(storage_dir, vim.fn.sha256(original_uri) .. EXTENSIONS[language])
end

local function reload_buffer(path)
    local bufnr = vim.fn.bufnr(path)
    if bufnr ~= -1 and vim.api.nvim_buf_is_loaded(bufnr) then
        vim.api.nvim_buf_call(bufnr, function()
            vim.cmd("silent! edit!")
        end)
    end
end

local function save(doc)
    if not EXTENSIONS[doc.language] then
        return
    end
    vim.fn.mkdir(storage_dir, "p")
    local path = path_for(doc.originalUri, doc.language)
    vim.fn.writefile(vim.split(doc.content, "\n", { plain = true }), path)
    reload_buffer(path)
    infos[vim.uri_from_fname(path)] = {
        original_uri = doc.originalUri,
        language = doc.language,
        character_indexes = doc.characterIndexes,
    }
end

function M.handler(err, result, _ctx)
    if err or type(result) ~= "table" then
        return
    end
    for _, doc in ipairs(result) do
        save(doc)
    end
end

function M.get_embedded_uri(original_uri, language)
    if not EXTENSIONS[language] then
        return nil
    end
    local uri = vim.uri_from_fname(path_for(original_uri, language))
    if infos[uri] then
        return uri
    end
    return nil
end

function M.get_info(embedded_uri)
    return infos[embedded_uri]
end

function M.cleanup()
    vim.fn.delete(storage_dir, "rf")
    infos = {}
end

return M
