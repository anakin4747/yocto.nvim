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

-- Copy of an enabled python config rooted at the project directory, with the
-- project's bitbake python paths for pyright/basedpyright (settings) and for
-- zubanls and others (environment). User values win and extraPaths extend.
local function embedded_python_config(config, project_dir, paths)
    config = vim.deepcopy(config)
    config.root_dir = project_dir
    config.root_markers = nil
    if #paths == 0 then
        return config
    end
    config.settings = config.settings or {}
    for _, section in ipairs({ "python", "basedpyright" }) do
        local user_paths = vim.tbl_get(config.settings, section, "analysis", "extraPaths") or {}
        config.settings = vim.tbl_deep_extend("force", config.settings, {
            [section] = { analysis = { extraPaths = vim.list_extend(vim.deepcopy(user_paths), paths) } },
        })
    end
    local joined = table.concat(paths, ":")
    config.cmd_env = vim.tbl_extend("keep", config.cmd_env or {}, { PYTHONPATH = joined, MYPYPATH = joined })
    return config
end

-- Start every python server enabled for the python filetype on the embedded
-- buffer, one client per Yocto project.
local function start_python_servers(bufnr, original_uri)
    M.select_server("python")
    local project_dir = M.project_dir(original_uri)
    local paths = M.bitbake_python_paths(M.project_root(vim.uri_to_fname(original_uri)))
    for _, config in ipairs(vim.lsp.get_configs({ enabled = true, filetype = "python" })) do
        local ok, err = pcall(vim.lsp.start, embedded_python_config(config, project_dir, paths), { bufnr = bufnr })
        if not ok then
            vim.lsp.log.error("yocto: failed to start " .. config.name .. ": " .. tostring(err))
        end
    end
end

-- Keep the embedded file loaded in a hidden buffer so language servers for
-- its filetype attach to it and receive its updates. Python buffers are
-- excluded from vim.lsp.enable (buftype) and get per-project servers instead.
local function sync_buffer(path, language, original_uri)
    local bufnr = vim.fn.bufnr(path)
    if bufnr ~= -1 and vim.api.nvim_buf_is_loaded(bufnr) then
        vim.api.nvim_buf_call(bufnr, function()
            vim.cmd("silent! edit!")
        end)
        return
    end
    bufnr = vim.fn.bufadd(path)
    vim.bo[bufnr].buflisted = false
    if language == "python" then
        vim.bo[bufnr].buftype = "nowrite"
    end
    vim.fn.bufload(bufnr)
    vim.bo[bufnr].filetype = FILETYPES[language]
    if language == "python" then
        start_python_servers(bufnr, original_uri)
    end
end

local function save(doc)
    if not EXTENSIONS[doc.language] then
        return
    end
    local path = path_for(doc.originalUri, doc.language)
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    vim.fn.writefile(vim.split(doc.content, "\n", { plain = true }), path)
    sync_buffer(path, doc.language, doc.originalUri)
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

local function buf_lines(bufnr)
    return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
end

-- Lines of the document at uri, from its loaded buffer or else from disk.
local function uri_lines(uri)
    local bufnr = vim.fn.bufnr(vim.uri_to_fname(uri))
    if bufnr ~= -1 and vim.api.nvim_buf_is_loaded(bufnr) then
        return buf_lines(bufnr)
    end
    local ok, lines = pcall(vim.fn.readfile, vim.uri_to_fname(uri))
    return ok and lines or {}
end

-- Map a range in any document back to the user's files: ranges in embedded
-- docs move to their recipe, other documents are returned unchanged.
-- Returns nil for ranges in text generated by the bitbake server.
local function original_location(uri, range)
    local info = infos[uri]
    if not info then
        return uri, range
    end
    local mapped = M.to_original_range(
        info.character_indexes,
        uri_lines(info.original_uri),
        uri_lines(uri),
        range
    )
    if not mapped then
        return nil
    end
    return info.original_uri, mapped
end

local function map_list(list, map_item)
    local mapped = {}
    for _, item in ipairs(list) do
        local result = map_item(item)
        if result ~= nil then
            table.insert(mapped, result)
        end
    end
    return mapped
end

-- Map a Location or LocationLink; links originate in embedded_uri.
local function map_location(location, embedded_uri)
    if location.targetUri then
        local uri, target_range = original_location(location.targetUri, location.targetRange)
        local _, selection_range = original_location(location.targetUri, location.targetSelectionRange)
        if not target_range or not selection_range then
            return nil
        end
        location.targetUri, location.targetRange, location.targetSelectionRange = uri, target_range, selection_range
        if location.originSelectionRange then
            location.originSelectionRange = select(2, original_location(embedded_uri, location.originSelectionRange))
        end
        return location
    end
    local uri, range = original_location(location.uri, location.range)
    if not range then
        return nil
    end
    return { uri = uri, range = range }
end

-- Map a Location, LocationLink or a list of them.
local function map_locations(result, embedded_uri)
    if result.uri or result.targetUri then
        return map_location(result, embedded_uri)
    end
    return map_list(result, function(location)
        return map_location(location, embedded_uri)
    end)
end

-- Map text edits of one document; edits in generated text are dropped.
local function map_edits(uri, edits)
    local new_uri
    local mapped = map_list(edits, function(edit)
        local edit_uri, range = original_location(uri, edit.range)
        if not range then
            return nil
        end
        new_uri = edit_uri
        return vim.tbl_extend("force", edit, { range = range })
    end)
    return new_uri or uri, mapped
end

local function map_workspace_edit(edit)
    local changes = {}
    local function add(uri, edits)
        local new_uri, mapped = map_edits(uri, edits)
        changes[new_uri] = vim.list_extend(changes[new_uri] or {}, mapped)
    end
    for uri, edits in pairs(edit.changes or {}) do
        add(uri, edits)
    end
    for _, change in ipairs(edit.documentChanges or {}) do
        if change.textDocument and change.edits then
            add(change.textDocument.uri, change.edits)
        end
    end
    return { changes = changes }
end

local function map_completion_item(item, embedded_uri)
    local text_edit = item.textEdit
    if text_edit then
        for _, key in ipairs({ "range", "insert", "replace" }) do
            if text_edit[key] then
                text_edit[key] = select(2, original_location(embedded_uri, text_edit[key]))
                if not text_edit[key] then
                    return nil
                end
            end
        end
    end
    if item.additionalTextEdits then
        local _, mapped = map_edits(embedded_uri, item.additionalTextEdits)
        if #mapped ~= #item.additionalTextEdits then
            return nil
        end
        item.additionalTextEdits = mapped
    end
    return item
end

-- Forwarded methods, their proxy capability and how to map their result back
-- to the recipe. `embedded_uri` is the doc the request was forwarded to.
local FORWARDED = {
    ["textDocument/hover"] = {
        capability = { hoverProvider = true },
        map = function(result, embedded_uri)
            if result.range then
                result.range = select(2, original_location(embedded_uri, result.range))
            end
            return result
        end,
    },
    ["textDocument/definition"] = { capability = { definitionProvider = true }, map = map_locations },
    ["textDocument/declaration"] = { capability = { declarationProvider = true }, map = map_locations },
    ["textDocument/typeDefinition"] = { capability = { typeDefinitionProvider = true }, map = map_locations },
    ["textDocument/implementation"] = { capability = { implementationProvider = true }, map = map_locations },
    ["textDocument/references"] = {
        capability = { referencesProvider = true },
        map = map_locations,
    },
    ["textDocument/documentHighlight"] = {
        capability = { documentHighlightProvider = true },
        map = function(result, embedded_uri)
            return map_list(result, function(highlight)
                highlight.range = select(2, original_location(embedded_uri, highlight.range))
                return highlight.range and highlight or nil
            end)
        end,
    },
    ["textDocument/completion"] = {
        capability = { completionProvider = { triggerCharacters = { ".", "$", "{", "/" } } },
        map = function(result, embedded_uri)
            local items = result.items or result
            local mapped = map_list(items, function(item)
                return map_completion_item(item, embedded_uri)
            end)
            if result.items then
                result.items = mapped
                return result
            end
            return mapped
        end,
    },
    ["textDocument/signatureHelp"] = {
        capability = { signatureHelpProvider = { triggerCharacters = { "(", "," } } },
    },
    ["textDocument/prepareRename"] = {
        map = function(result, embedded_uri)
            if result.start then
                return select(2, original_location(embedded_uri, result))
            elseif result.range then
                result.range = select(2, original_location(embedded_uri, result.range))
                return result.range and result or nil
            end
            return result
        end,
    },
    ["textDocument/rename"] = {
        capability = { renameProvider = { prepareProvider = true } },
        map = map_workspace_edit,
    },
}

local PROXY_CAPABILITIES = {}
for _, forwarded in pairs(FORWARDED) do
    PROXY_CAPABILITIES = vim.tbl_extend("force", PROXY_CAPABILITIES, forwarded.capability or {})
end

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
            local map = FORWARDED[method].map
            if result and result ~= vim.NIL and map then
                result = map(result, embedded_uri)
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
                elseif FORWARDED[method] then
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

-- Copy the LSP diagnostics of an embedded buffer onto its recipe buffer with
-- mapped ranges, one namespace per embedded language. Diagnostics in text
-- generated by the bitbake server are dropped.
local diagnostic_namespaces = {}

function M.sync_diagnostics(embedded_buf)
    local embedded_uri = vim.uri_from_bufnr(embedded_buf)
    local info = infos[embedded_uri]
    if not info then
        return
    end
    local recipe_buf = vim.fn.bufnr(vim.uri_to_fname(info.original_uri))
    if recipe_buf == -1 or not vim.api.nvim_buf_is_loaded(recipe_buf) then
        return
    end
    diagnostic_namespaces[info.language] = diagnostic_namespaces[info.language]
        or vim.api.nvim_create_namespace("yocto_embedded_" .. info.language)

    local recipe_lines = buf_lines(recipe_buf)
    local embedded_lines = buf_lines(embedded_buf)
    local function byte_col(lnum, character)
        local line = recipe_lines[lnum + 1] or ""
        return vim.str_byteindex(line, "utf-16", math.min(character, vim.str_utfindex(line, "utf-16")), false)
    end

    local mapped = {}
    for _, diagnostic in ipairs(vim.diagnostic.get(embedded_buf)) do
        local lsp = vim.tbl_get(diagnostic, "user_data", "lsp")
        local range = lsp
            and M.to_original_range(info.character_indexes, recipe_lines, embedded_lines, lsp.range)
        if range then
            table.insert(mapped, {
                lnum = range.start.line,
                col = byte_col(range.start.line, range.start.character),
                end_lnum = range["end"].line,
                end_col = byte_col(range["end"].line, range["end"].character),
                severity = diagnostic.severity,
                message = diagnostic.message,
                source = diagnostic.source,
                code = diagnostic.code,
            })
        end
    end
    vim.diagnostic.set(diagnostic_namespaces[info.language], recipe_buf, mapped)
end

function M.start_proxy(bufnr)
    return vim.lsp.start({ name = PROXY_NAME, cmd = proxy_cmd }, { bufnr = bufnr })
end

return M
