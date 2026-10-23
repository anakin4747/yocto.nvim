-- Handles the bitbake/EmbeddedLanguageDocs notification from
-- bitbake-language-server by writing embedded bash/python docs to disk.

local M = {}

local EXTENSIONS = { bash = ".sh", python = ".py" }

-- Inside Neovim's per-session temp directory, which Neovim deletes on exit.
M.storage_dir = vim.fn.tempname()

local infos = {} -- embedded_uri -> { original_uri, language, character_indexes }

-- Directory holding the embedded docs of all recipes in the same Yocto
-- project as original_uri. Used as workspace root of embedded servers.
function M.project_dir(original_uri)
    local root = M.project_root(vim.uri_to_fname(original_uri)) or ""
    return vim.fs.joinpath(M.storage_dir, vim.fn.sha256(root))
end

local function path_for(original_uri, language)
    return vim.fs.joinpath(M.project_dir(original_uri), vim.fn.sha256(original_uri) .. EXTENSIONS[language])
end

local FILETYPES = { bash = "sh", python = "python" }

-- Keep the embedded file loaded in a hidden buffer so language servers
-- enabled for its filetype attach to it and receive its updates.
local function sync_buffer(path, language)
    local bufnr = vim.fn.bufnr(path)
    if bufnr ~= -1 and vim.api.nvim_buf_is_loaded(bufnr) then
        vim.api.nvim_buf_call(bufnr, function()
            vim.cmd("silent! edit!")
        end)
        return
    end
    bufnr = vim.fn.bufadd(path)
    vim.bo[bufnr].buflisted = false
    vim.fn.bufload(bufnr)
    vim.bo[bufnr].filetype = FILETYPES[language]
end

local function save(doc)
    if not EXTENSIONS[doc.language] then
        return
    end
    local path = path_for(doc.originalUri, doc.language)
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    vim.fn.writefile(vim.split(doc.content, "\n", { plain = true }), path)
    sync_buffer(path, doc.language)
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
    -- The server sends the doc array as a single positional parameter.
    if vim.islist(result[1]) then
        result = result[1]
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

-- Same default as the vscode-bitbake extension.
local DEFAULT_BITBAKE_SETTINGS = { pathToBitbakeFolder = "${workspaceFolder}/sources/poky/bitbake" }

-- Top directory of the Yocto project containing path, or nil.
function M.project_root(path)
    return vim.fs.root(path, { { ".vscode", "sources", "layers", "build" } })
end

-- bitbake.* settings from <root>/.vscode/settings.json, accepting both
-- "bitbake.key" and nested "bitbake": { key } forms. VS Code allows
-- comments and trailing commas in that file.
local function read_vscode_bitbake_settings(root)
    local path = vim.fs.joinpath(root, ".vscode", "settings.json")
    local ok, lines = pcall(vim.fn.readfile, path)
    if not ok or #lines == 0 then
        return {}
    end
    local text = table.concat(lines, "\n"):gsub(",(%s*[}%]])", "%1")
    local decoded_ok, decoded = pcall(vim.json.decode, text, { skip_comments = true })
    if not decoded_ok or type(decoded) ~= "table" then
        return {}
    end
    local settings = type(decoded.bitbake) == "table" and decoded.bitbake or {}
    for key, value in pairs(decoded) do
        local name = type(key) == "string" and key:match("^bitbake%.(.+)$")
        if name then
            settings[name] = value
        end
    end
    return settings
end

local function is_dir(path)
    return vim.fn.isdirectory(path) == 1
end

-- Python import paths of bitbake's `bb` and openembedded-core's `oe` modules
-- for the project at root. pathToBitbakeFolder from the project's
-- .vscode/settings.json wins over the usual poky and oe-core layouts.
function M.bitbake_python_paths(root)
    if not root then
        return {}
    end
    local candidates = {}
    local configured = read_vscode_bitbake_settings(root).pathToBitbakeFolder
    if type(configured) == "string" then
        table.insert(candidates, (configured:gsub("%${workspaceFolder}", root)))
    end
    for _, prefix in ipairs({ "sources", "layers", "." }) do
        table.insert(candidates, vim.fs.joinpath(root, prefix, "poky", "bitbake"))
        table.insert(candidates, vim.fs.joinpath(root, prefix, "bitbake"))
    end
    local bitbake = vim.iter(candidates):find(function(dir)
        return is_dir(vim.fs.joinpath(dir, "lib", "bb"))
    end)
    if not bitbake then
        return {}
    end
    bitbake = vim.fs.normalize(bitbake)

    local oe_candidates = { vim.fs.joinpath(vim.fs.dirname(bitbake), "meta", "lib") }
    for _, prefix in ipairs({ "sources", "layers", "." }) do
        table.insert(oe_candidates, vim.fs.joinpath(root, prefix, "openembedded-core", "meta", "lib"))
    end
    local oe = vim.iter(oe_candidates):find(function(dir)
        return is_dir(vim.fs.joinpath(dir, "oe"))
    end)
    local paths = { vim.fs.joinpath(bitbake, "lib") }
    if oe then
        table.insert(paths, vim.fs.normalize(oe))
    end
    return paths
end

-- Settings are applied in place: the client shares this settings table and
-- sends it in workspace/didChangeConfiguration after initialization.
local function bitbake_before_init(_, config)
    config.settings = config.settings or {}
    local project = config.root_dir and read_vscode_bitbake_settings(config.root_dir) or {}
    config.settings.bitbake = vim.tbl_deep_extend(
        "force",
        DEFAULT_BITBAKE_SETTINGS,
        project,
        config.settings.bitbake or {}
    )
end

local DEFAULT_CONFIGS = {
    yocto_bitbake = {
        cmd = { "language-server-bitbake", "--stdio" },
        filetypes = { "bitbake" },
        root_markers = { ".vscode", "sources", ".git" },
        settings = {},
        before_init = bitbake_before_init,
    },
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

local function map_range(map_position, character_indexes, original_lines, embedded_lines, range)
    local start = map_position(character_indexes, original_lines, embedded_lines, range.start)
    local finish = map_position(character_indexes, original_lines, embedded_lines, range["end"])
    if not start or not finish then
        return nil
    end
    return { start = start, ["end"] = finish }
end

function M.to_embedded_range(...)
    return map_range(M.to_embedded_position, ...)
end

function M.to_original_range(...)
    return map_range(M.to_original_position, ...)
end

-- In-process language server that forwards requests on bitbake buffers to the
-- language servers attached to the embedded documents.
local PROXY_NAME = "yocto_embedded"
local PROXY_CAPABILITIES = { hoverProvider = true }

local function buf_lines(bufnr)
    return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
end

-- Per-method mapping of embedded results back to the recipe. `to_original`
-- maps an embedded range, returning nil when it is generated text.
local RESULT_MAPPERS = {
    ["textDocument/hover"] = function(result, to_original)
        if result.range then
            result.range = to_original(result.range)
        end
        return result
    end,
}

-- Ask the bitbake server which embedded language is at params.position,
-- map the request into that embedded doc and send it to its language server.
local function forward(method, params, reply)
    local uri = params.textDocument.uri
    local recipe_buf = vim.uri_to_bufnr(uri)
    local bitbake = vim.iter(vim.lsp.get_clients({ bufnr = recipe_buf })):find(function(client)
        return client.name ~= PROXY_NAME
    end)
    if not bitbake then
        return reply(nil, nil)
    end
    bitbake:request("bitbake/requestEmbeddedLanguageDocInfos", {
        uriString = uri,
        position = params.position,
    }, function(err, language)
        local embedded_uri = not err and type(language) == "string" and M.get_embedded_uri(uri, language)
        if not embedded_uri then
            return reply(nil, nil)
        end
        local embedded_buf = vim.uri_to_bufnr(embedded_uri)
        local position = M.to_embedded_position(
            M.get_info(embedded_uri).character_indexes,
            buf_lines(recipe_buf),
            buf_lines(embedded_buf),
            params.position
        )
        local target = vim.lsp.get_clients({ bufnr = embedded_buf, method = method })[1]
        if not position or not target then
            return reply(nil, nil)
        end
        local embedded_params = vim.tbl_extend("force", params, {
            textDocument = { uri = embedded_uri },
            position = position,
        })
        target:request(method, embedded_params, function(err2, result)
            local map_result = RESULT_MAPPERS[method]
            if result and map_result then
                local character_indexes = M.get_info(embedded_uri).character_indexes
                local recipe_lines, embedded_lines = buf_lines(recipe_buf), buf_lines(embedded_buf)
                result = map_result(result, function(range)
                    return M.to_original_range(character_indexes, recipe_lines, embedded_lines, range)
                end)
            end
            reply(err2, result)
        end, embedded_buf)
    end, recipe_buf)
end

local function proxy_cmd(dispatchers)
    local closing = false
    local next_id = 0
    local function close()
        if not closing then
            closing = true
            vim.schedule(function()
                dispatchers.on_exit(0, 0)
            end)
        end
    end
    return {
        request = function(method, params, callback, notify_reply_callback)
            next_id = next_id + 1
            local id = next_id
            local function reply(err, result)
                callback(err, result)
                if notify_reply_callback then
                    notify_reply_callback(id)
                end
            end
            vim.schedule(function()
                if method == "initialize" then
                    reply(nil, { capabilities = PROXY_CAPABILITIES })
                elseif method == "textDocument/hover" then
                    forward(method, params, reply)
                else
                    reply(nil, nil)
                end
            end)
            return true, id
        end,
        notify = function(method)
            if method == "exit" then
                close()
            end
            return true
        end,
        is_closing = function()
            return closing
        end,
        terminate = close,
    }
end

function M.start_proxy(bufnr)
    return vim.lsp.start({ name = PROXY_NAME, cmd = proxy_cmd }, { bufnr = bufnr })
end

return M
