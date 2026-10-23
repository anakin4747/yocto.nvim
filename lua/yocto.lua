-- Handles the bitbake/EmbeddedLanguageDocs notification from
-- bitbake-language-server by writing embedded bash/python docs to disk.

local M = {}

local EXTENSIONS = { bash = ".sh", python = ".py" }

M.storage_dir = vim.fs.joinpath(vim.fn.stdpath("cache"), "yocto", "embedded-documents")

local infos = {} -- embedded_uri -> { original_uri, language, character_indexes }

local function path_for(original_uri, language)
    return vim.fs.joinpath(M.storage_dir, vim.fn.sha256(original_uri) .. EXTENSIONS[language])
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
    vim.fn.mkdir(M.storage_dir, "p")
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

local DEFAULT_CONFIGS = {
    yocto_bitbake = { cmd = { "language-server-bitbake", "--stdio" }, filetypes = { "bitbake" } },
    yocto_bash = { cmd = { "bash-language-server", "start" }, filetypes = { "sh" } },
    yocto_python = { cmd = { "pyright-langserver", "--stdio" }, filetypes = { "python" } },
}

local DEFAULT_FOR_FILETYPE = {
    bitbake = "yocto_bitbake",
    sh = "yocto_bash",
    python = "yocto_python",
}

-- Register fallback configs; anything the user already set wins.
function M.register_defaults()
    for name, defaults in pairs(DEFAULT_CONFIGS) do
        vim.lsp.config[name] = vim.tbl_extend("force", defaults, vim.lsp.config[name] or {})
    end
end

-- Enable the fallback config for filetype unless the user enabled one.
function M.select_server(filetype)
    local default = DEFAULT_FOR_FILETYPE[filetype]
    if not default then
        return
    end
    for _, config in ipairs(vim.lsp.get_configs({ enabled = true, filetype = filetype })) do
        if config.name ~= default then
            return
        end
    end
    vim.lsp.enable(default)
end

local function utf16_len(line)
    return vim.str_utfindex(line, "utf-16")
end

-- LSP position (utf-16) -> offset in the whole document, counting "\n".
function M.position_to_offset(lines, pos)
    local offset = 0
    for i = 1, pos.line do
        offset = offset + utf16_len(lines[i]) + 1
    end
    return offset + pos.character
end

-- Offset in the whole document -> LSP position (utf-16); nil past the end.
function M.offset_to_position(lines, offset)
    for i, line in ipairs(lines) do
        local len = utf16_len(line)
        if offset <= len then
            return { line = i - 1, character = offset }
        end
        offset = offset - len - 1
    end
    return nil
end

-- Original document position -> embedded document position; nil if unmapped.
function M.to_embedded_position(character_indexes, original_lines, embedded_lines, pos)
    local embedded_offset = character_indexes[M.position_to_offset(original_lines, pos) + 1]
    if not embedded_offset then
        return nil
    end
    return M.offset_to_position(embedded_lines, embedded_offset)
end

-- Embedded document position -> original document position; nil for
-- generated text. Uses the first original offset mapping to it.
function M.to_original_position(character_indexes, original_lines, embedded_lines, pos)
    local embedded_offset = M.position_to_offset(embedded_lines, pos)
    for i, value in ipairs(character_indexes) do
        if value == embedded_offset then
            return M.offset_to_position(original_lines, i - 1)
        end
    end
    return nil
end

function M.cleanup()
    vim.fn.delete(M.storage_dir, "rf")
    infos = {}
end

return M
