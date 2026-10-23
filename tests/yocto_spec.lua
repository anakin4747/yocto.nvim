local describe = require("plenary.busted").describe
local it = require("plenary.busted").it
local before_each = require("plenary.busted").before_each
local after_each = require("plenary.busted").after_each

local ORIG = "file:///tmp/meta/recipes/foo/foo_1.0.bb"
local OTHER = "file:///tmp/meta/recipes/bar/bar_1.0.bb"

local function doc(lang, content, idx, orig)
    return {
        originalUri = orig or ORIG,
        language = lang,
        content = content,
        characterIndexes = idx or {},
    }
end

-- Test teardown: wipe embedded buffers and files under dir.
local function remove_storage(dir)
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
        if vim.startswith(vim.api.nvim_buf_get_name(bufnr), dir) then
            vim.api.nvim_buf_delete(bufnr, { force = true })
        end
    end
    vim.fn.delete(dir, "rf")
end

local function read(uri)
    return table.concat(vim.fn.readfile(vim.uri_to_fname(uri)), "\n")
end

describe("embedded language docs handler", function()
    local docs, dir

    before_each(function()
        dir = vim.fn.tempname()
        docs = require("yocto")
        docs.storage_dir = dir
    end)

    after_each(function()
        remove_storage(docs.storage_dir)
    end)

    it("writes a .sh file for a bash doc", function()
        docs.handler(nil, { doc("bash", "echo hi") }, {})
        local uri = docs.get_embedded_uri(ORIG, "bash")
        assert.is_not_nil(uri:match("%.sh$"))
        assert.are.equal("echo hi", read(uri))
    end)

    it("writes a .py file for a python doc", function()
        docs.handler(nil, { doc("python", "x = 1") }, {})
        local uri = docs.get_embedded_uri(ORIG, "python")
        assert.is_not_nil(uri:match("%.py$"))
        assert.are.equal("x = 1", read(uri))
    end)

    it("writes both files from a single notification", function()
        docs.handler(nil, { doc("bash", "echo hi"), doc("python", "x = 1") }, {})
        assert.are.equal("echo hi", read(docs.get_embedded_uri(ORIG, "bash")))
        assert.are.equal("x = 1", read(docs.get_embedded_uri(ORIG, "python")))
    end)

    it("places files under storage_dir", function()
        docs.handler(nil, { doc("bash", "echo hi") }, {})
        local path = vim.uri_to_fname(docs.get_embedded_uri(ORIG, "bash"))
        assert.are.equal(dir, vim.fs.dirname(path))
    end)

    it("names files with the sha256 of the original uri", function()
        docs.handler(nil, { doc("bash", "echo hi") }, {})
        local path = vim.uri_to_fname(docs.get_embedded_uri(ORIG, "bash"))
        assert.are.equal(vim.fn.sha256(ORIG) .. ".sh", vim.fs.basename(path))
    end)

    it("uses the same path for the same original uri", function()
        docs.handler(nil, { doc("bash", "a") }, {})
        local first = docs.get_embedded_uri(ORIG, "bash")
        docs.handler(nil, { doc("bash", "b") }, {})
        assert.are.equal(first, docs.get_embedded_uri(ORIG, "bash"))
    end)

    it("uses different paths for different original uris", function()
        docs.handler(nil, { doc("bash", "a"), doc("bash", "b", {}, OTHER) }, {})
        assert.are_not.equal(
            docs.get_embedded_uri(ORIG, "bash"),
            docs.get_embedded_uri(OTHER, "bash")
        )
    end)

    it("overwrites content on a subsequent notification", function()
        docs.handler(nil, { doc("bash", "old") }, {})
        docs.handler(nil, { doc("bash", "new") }, {})
        assert.are.equal("new", read(docs.get_embedded_uri(ORIG, "bash")))
    end)

    it("reloads an already loaded buffer of the embedded file", function()
        docs.handler(nil, { doc("bash", "old") }, {})
        local path = vim.uri_to_fname(docs.get_embedded_uri(ORIG, "bash"))
        local bufnr = vim.fn.bufadd(path)
        vim.fn.bufload(bufnr)

        docs.handler(nil, { doc("bash", "new") }, {})

        assert.are.same({ "new" }, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
        vim.api.nvim_buf_delete(bufnr, { force = true })
    end)

    it("records info for an embedded uri", function()
        docs.handler(nil, { doc("python", "x", { 0, 1 }) }, {})
        local info = docs.get_info(docs.get_embedded_uri(ORIG, "python"))
        assert.are.same({
            original_uri = ORIG,
            language = "python",
            character_indexes = { 0, 1 },
        }, info)
    end)

    it("updates recorded character indexes on a subsequent notification", function()
        docs.handler(nil, { doc("python", "x", { 0 }) }, {})
        docs.handler(nil, { doc("python", "xy", { 0, 1 }) }, {})
        local info = docs.get_info(docs.get_embedded_uri(ORIG, "python"))
        assert.are.same({ 0, 1 }, info.character_indexes)
    end)

    it("returns nil info for an unknown embedded uri", function()
        assert.is_nil(docs.get_info("file:///nowhere.sh"))
    end)

    it("returns nil embedded uri before any notification", function()
        assert.is_nil(docs.get_embedded_uri(ORIG, "bash"))
    end)

    it("does nothing for an empty result", function()
        docs.handler(nil, {}, {})
        assert.are.equal(0, vim.fn.isdirectory(dir))
    end)

    it("accepts docs wrapped in positional params as sent by the server", function()
        docs.handler(nil, { { doc("bash", "echo hi"), doc("python", "x = 1") } }, {})
        assert.are.equal("echo hi", read(docs.get_embedded_uri(ORIG, "bash")))
        assert.are.equal("x = 1", read(docs.get_embedded_uri(ORIG, "python")))
    end)

    it("ignores unknown languages", function()
        docs.handler(nil, { doc("perl", "print 1") }, {})
        assert.is_nil(docs.get_embedded_uri(ORIG, "perl"))
        assert.are.equal(0, vim.fn.isdirectory(dir))
    end)

    it("does nothing when err is set", function()
        docs.handler({ code = -32603, message = "boom" }, { doc("bash", "a") }, {})
        assert.is_nil(docs.get_embedded_uri(ORIG, "bash"))
    end)

end)

local DEFAULT_NAMES = { "yocto_bitbake", "yocto_bash", "yocto_python" }

-- In-process fake language server. Records requests and notifications into
-- `messages`. `opts.handlers[method](params)` answers requests and
-- `opts.capabilities` extends the advertised capabilities.
local function fake_cmd(messages, opts)
    opts = opts or {}
    local capabilities = vim.tbl_extend(
        "force",
        { textDocumentSync = { openClose = true, change = 1 } },
        opts.capabilities or {}
    )
    return function(dispatchers)
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
                if messages then
                    table.insert(messages, { method = method, params = params })
                end
                vim.schedule(function()
                    local result
                    if method == "initialize" then
                        result = { capabilities = capabilities }
                    elseif opts.handlers and opts.handlers[method] then
                        result = opts.handlers[method](params)
                    end
                    callback(nil, result)
                    if notify_reply_callback then
                        notify_reply_callback(id)
                    end
                end)
                return true, id
            end,
            notify = function(method, params)
                if messages then
                    table.insert(messages, { method = method, params = params })
                end
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
end

-- Disable all test configs and wait for their clients to exit. Clients
-- still initializing are hidden from get_clients() and vim.lsp.enable(false)
-- unless _uninitialized is passed; they would otherwise be reused later.
local function stop_servers()
    vim.lsp.enable({ "user_server", "user_bitbake", "user_python", unpack(DEFAULT_NAMES) }, false)
    for _, client in ipairs(vim.lsp.get_clients({ _uninitialized = true })) do
        client:stop(true)
    end
    vim.wait(1000, function()
        return #vim.lsp.get_clients({ _uninitialized = true }) == 0
    end)
end

describe("default language server configs", function()
    local yocto

    before_each(function()
        for _, name in ipairs(DEFAULT_NAMES) do
            vim.lsp.config[name] = {}
        end
        yocto = require("yocto")
    end)

    it("registers yocto_bitbake for bitbake files", function()
        yocto.register_defaults()
        assert.are.same({ "language-server-bitbake", "--stdio" }, vim.lsp.config.yocto_bitbake.cmd)
        assert.are.same({ "bitbake" }, vim.lsp.config.yocto_bitbake.filetypes)
    end)

    it("registers yocto_bash for sh files", function()
        yocto.register_defaults()
        assert.are.same({ "bash-language-server", "start" }, vim.lsp.config.yocto_bash.cmd)
        assert.are.same({ "sh" }, vim.lsp.config.yocto_bash.filetypes)
    end)

    it("registers yocto_python for python files", function()
        yocto.register_defaults()
        assert.are.same({ "pyright-langserver", "--stdio" }, vim.lsp.config.yocto_python.cmd)
        assert.are.same({ "python" }, vim.lsp.config.yocto_python.filetypes)
    end)

    it("keeps user settings made before registration", function()
        vim.lsp.config("yocto_bash", { cmd = { "my-bash-ls" } })
        yocto.register_defaults()
        assert.are.same({ "my-bash-ls" }, vim.lsp.config.yocto_bash.cmd)
        assert.are.same({ "sh" }, vim.lsp.config.yocto_bash.filetypes)
    end)

    it("lets user settings made after registration win", function()
        yocto.register_defaults()
        vim.lsp.config("yocto_bash", { cmd = { "my-bash-ls" } })
        assert.are.same({ "my-bash-ls" }, vim.lsp.config.yocto_bash.cmd)
    end)
end)

describe("language server selection", function()
    local buf

    local function open_with_filetype(ft)
        buf = vim.api.nvim_create_buf(true, false)
        vim.bo[buf].filetype = ft
    end

    before_each(function()
        stop_servers()
        for _, name in ipairs(DEFAULT_NAMES) do
            vim.lsp.config[name] = {}
        end
        require("yocto").register_defaults()
    end)

    after_each(function()
        stop_servers()
        if buf and vim.api.nvim_buf_is_valid(buf) then
            vim.api.nvim_buf_delete(buf, { force = true })
        end
    end)

    it("enables yocto_bash for sh when no other config is enabled", function()
        open_with_filetype("sh")
        assert.is_true(vim.lsp.is_enabled("yocto_bash"))
    end)

    it("enables yocto_python for python when no other config is enabled", function()
        open_with_filetype("python")
        assert.is_true(vim.lsp.is_enabled("yocto_python"))
    end)

    it("enables yocto_bitbake for bitbake when no other config is enabled", function()
        open_with_filetype("bitbake")
        assert.is_true(vim.lsp.is_enabled("yocto_bitbake"))
    end)

    it("does not enable the default when a user config is enabled for the filetype", function()
        vim.lsp.config("user_server", { cmd = fake_cmd(), filetypes = { "sh" } })
        vim.lsp.enable("user_server")
        open_with_filetype("sh")
        assert.is_false(vim.lsp.is_enabled("yocto_bash"))
    end)

    it("ignores enabled user configs for other filetypes", function()
        vim.lsp.config("user_server", { cmd = fake_cmd(), filetypes = { "lua" } })
        vim.lsp.enable("user_server")
        open_with_filetype("sh")
        assert.is_true(vim.lsp.is_enabled("yocto_bash"))
    end)

    it("ignores user configs that are not enabled", function()
        vim.lsp.config("user_server", { cmd = fake_cmd(), filetypes = { "sh" } })
        open_with_filetype("sh")
        assert.is_true(vim.lsp.is_enabled("yocto_bash"))
    end)

    it("enables nothing for unrelated filetypes", function()
        open_with_filetype("lua")
        for _, name in ipairs(DEFAULT_NAMES) do
            assert.is_false(vim.lsp.is_enabled(name))
        end
    end)
end)

describe("notification handler registration", function()
    local yocto

    before_each(function()
        yocto = require("yocto")
        yocto.storage_dir = vim.fn.tempname()
    end)

    after_each(function()
        remove_storage(yocto.storage_dir)
    end)

    it("handles bitbake/EmbeddedLanguageDocs through vim.lsp.handlers", function()
        vim.lsp.handlers["bitbake/EmbeddedLanguageDocs"](nil, { doc("bash", "echo hi") }, {})
        assert.are.equal("echo hi", read(yocto.get_embedded_uri(ORIG, "bash")))
    end)
end)

local function pos(line, character)
    return { line = line, character = character }
end

describe("offset conversion", function()
    local yocto = require("yocto")
    local lines = { "ab", "", "cé", "x😀y" }

    it("maps the first position to offset 0", function()
        assert.are.equal(0, yocto.position_to_offset(lines, pos(0, 0)))
    end)

    it("counts newlines of previous lines", function()
        assert.are.equal(3, yocto.position_to_offset(lines, pos(1, 0)))
    end)

    it("counts empty lines as one newline", function()
        assert.are.equal(4, yocto.position_to_offset(lines, pos(2, 0)))
    end)

    it("counts non-ascii characters as one utf-16 unit", function()
        assert.are.equal(7, yocto.position_to_offset(lines, pos(3, 0)))
    end)

    it("counts astral characters as two utf-16 units", function()
        assert.are.equal(10, yocto.position_to_offset(lines, pos(3, 3)))
    end)

    it("maps offset 0 to the first position", function()
        assert.are.same(pos(0, 0), yocto.offset_to_position(lines, 0))
    end)

    it("maps a newline offset to the end of its line", function()
        assert.are.same(pos(0, 2), yocto.offset_to_position(lines, 2))
    end)

    it("maps offsets after newlines to the next line", function()
        assert.are.same(pos(2, 0), yocto.offset_to_position(lines, 4))
    end)

    it("maps offsets after non-ascii characters in utf-16 units", function()
        assert.are.same(pos(3, 3), yocto.offset_to_position(lines, 10))
    end)

    it("maps the end of the document", function()
        assert.are.same(pos(3, 4), yocto.offset_to_position(lines, 11))
    end)

    it("returns nil past the end of the document", function()
        assert.is_nil(yocto.offset_to_position(lines, 12))
    end)
end)

-- Recipe:                       Embedded python:
--   0 python do_foo() {           0 def do_foo():
--   1     x = 1                   1     x = 1
--   2 }
-- "do_foo" and the body map to their embedded counterparts; the rest of
-- line 0 maps to the ":" (offset 13), so "def " has no original.
local RECIPE = { "python do_foo() {", "    x = 1", "}" }
local EMBEDDED = { "def do_foo():", "    x = 1" }
local INDEXES = {}
for o = 0, 28 do
    local v
    if o <= 6 or (o >= 13 and o <= 17) then
        v = 13
    elseif o <= 12 then
        v = o - 3
    elseif o <= 27 then
        v = o - 4
    else
        v = 23
    end
    INDEXES[o + 1] = v
end

describe("position mapping", function()
    local yocto = require("yocto")

    describe("to_embedded_position", function()
        it("maps through an identity mapping unchanged", function()
            local lines = { "ab", "c" }
            assert.are.same(
                pos(1, 0),
                yocto.to_embedded_position({ 0, 1, 2, 3, 4 }, lines, lines, pos(1, 0))
            )
        end)

        it("maps a name in the function header", function()
            assert.are.same(
                pos(0, 4),
                yocto.to_embedded_position(INDEXES, RECIPE, EMBEDDED, pos(0, 7))
            )
        end)

        it("maps a position in the function body", function()
            assert.are.same(
                pos(1, 4),
                yocto.to_embedded_position(INDEXES, RECIPE, EMBEDDED, pos(1, 4))
            )
        end)

        it("returns nil past the end of the character indexes", function()
            assert.is_nil(yocto.to_embedded_position(INDEXES, RECIPE, EMBEDDED, pos(2, 1)))
        end)
    end)

    describe("to_original_position", function()
        it("maps a position in the function body back", function()
            assert.are.same(
                pos(1, 4),
                yocto.to_original_position(INDEXES, RECIPE, EMBEDDED, pos(1, 4))
            )
        end)

        it("maps a name in the function header back", function()
            assert.are.same(
                pos(0, 7),
                yocto.to_original_position(INDEXES, RECIPE, EMBEDDED, pos(0, 4))
            )
        end)

        it("returns nil for generated text", function()
            assert.is_nil(yocto.to_original_position(INDEXES, RECIPE, EMBEDDED, pos(0, 1)))
        end)

        it("uses the first matching index", function()
            assert.are.same(
                pos(0, 0),
                yocto.to_original_position(INDEXES, RECIPE, EMBEDDED, pos(0, 13))
            )
        end)
    end)
end)

describe("range mapping", function()
    local yocto = require("yocto")

    local function range(sl, sc, el, ec)
        return { start = pos(sl, sc), ["end"] = pos(el, ec) }
    end

    it("maps an original range to the embedded document", function()
        assert.are.same(
            range(0, 4, 0, 9),
            yocto.to_embedded_range(INDEXES, RECIPE, EMBEDDED, range(0, 7, 0, 12))
        )
    end)

    it("returns nil when an original range end is unmapped", function()
        assert.is_nil(yocto.to_embedded_range(INDEXES, RECIPE, EMBEDDED, range(1, 0, 2, 1)))
    end)

    it("maps an embedded range back to the original document", function()
        assert.are.same(
            range(1, 4, 1, 9),
            yocto.to_original_range(INDEXES, RECIPE, EMBEDDED, range(1, 4, 1, 9))
        )
    end)

    it("returns nil when an embedded range start is generated text", function()
        assert.is_nil(yocto.to_original_range(INDEXES, RECIPE, EMBEDDED, range(0, 0, 0, 4)))
    end)
end)

describe("embedded buffers", function()
    local yocto

    local function embedded_buf(language)
        return vim.fn.bufnr(vim.uri_to_fname(yocto.get_embedded_uri(ORIG, language)))
    end

    before_each(function()
        yocto = require("yocto")
        yocto.storage_dir = vim.fn.tempname()
    end)

    after_each(function()
        stop_servers()
        remove_storage(yocto.storage_dir)
    end)

    it("loads the bash doc into a buffer with filetype sh", function()
        yocto.handler(nil, { doc("bash", "echo hi") }, {})
        local bufnr = embedded_buf("bash")
        assert.is_true(vim.api.nvim_buf_is_loaded(bufnr))
        assert.are.equal("sh", vim.bo[bufnr].filetype)
    end)

    it("loads the python doc into a buffer with filetype python", function()
        yocto.handler(nil, { doc("python", "x = 1") }, {})
        local bufnr = embedded_buf("python")
        assert.is_true(vim.api.nvim_buf_is_loaded(bufnr))
        assert.are.equal("python", vim.bo[bufnr].filetype)
    end)

    -- Latest text of uri as seen by the fake server, from didOpen/didChange.
    local function server_text(messages, uri)
        local text
        for _, m in ipairs(messages) do
            local td = m.params and m.params.textDocument
            if td and td.uri == uri then
                if m.method == "textDocument/didOpen" then
                    text = td.text
                elseif m.method == "textDocument/didChange" then
                    text = m.params.contentChanges[#m.params.contentChanges].text
                elseif m.method == "textDocument/didClose" then
                    text = nil
                end
            end
        end
        return text
    end

    local function enable_user_server(filetype, messages)
        vim.lsp.config("user_server", { cmd = fake_cmd(messages), filetypes = { filetype } })
        vim.lsp.enable("user_server")
    end

    it("opens the bash doc in the language server enabled for sh", function()
        local messages = {}
        enable_user_server("sh", messages)
        yocto.handler(nil, { doc("bash", "echo hi") }, {})
        local uri = yocto.get_embedded_uri(ORIG, "bash")
        assert.is_true((vim.wait(1000, function()
            return server_text(messages, uri) == "echo hi\n"
        end)))
    end)

    it("opens the python doc in the language server enabled for python", function()
        local messages = {}
        enable_user_server("python", messages)
        yocto.handler(nil, { doc("python", "x = 1") }, {})
        local uri = yocto.get_embedded_uri(ORIG, "python")
        assert.is_true((vim.wait(1000, function()
            return server_text(messages, uri) == "x = 1\n"
        end)))
    end)

    it("sends updated content to the language server", function()
        local messages = {}
        enable_user_server("sh", messages)
        yocto.handler(nil, { doc("bash", "old") }, {})
        local uri = yocto.get_embedded_uri(ORIG, "bash")
        vim.wait(1000, function()
            return server_text(messages, uri) == "old\n"
        end)
        yocto.handler(nil, { doc("bash", "new") }, {})
        assert.is_true((vim.wait(1000, function()
            return server_text(messages, uri) == "new\n"
        end)))
    end)

    it("does not list the embedded buffer", function()
        yocto.handler(nil, { doc("bash", "echo hi") }, {})
        assert.is_false(vim.bo[embedded_buf("bash")].buflisted)
    end)
end)

describe("embedded proxy client", function()
    local yocto, recipe_buf

    local function proxy_client()
        return vim.lsp.get_clients({ bufnr = recipe_buf, name = "yocto_embedded" })[1]
    end

    before_each(function()
        yocto = require("yocto")
        yocto.storage_dir = vim.fn.tempname()
        recipe_buf = vim.api.nvim_create_buf(true, false)
        vim.api.nvim_buf_set_name(recipe_buf, vim.uri_to_fname(ORIG))
        vim.api.nvim_buf_set_lines(recipe_buf, 0, -1, false, RECIPE)
    end)

    after_each(function()
        stop_servers()
        remove_storage(yocto.storage_dir)
        vim.api.nvim_buf_delete(recipe_buf, { force = true })
    end)

    -- Fake bitbake server reporting `language` everywhere, fake python server
    -- answering hover with `hover`, and the do_foo fixture as embedded doc.
    local function start_servers(opts)
        local python_messages = {}
        vim.lsp.config("user_bitbake", {
            cmd = fake_cmd(nil, {
                handlers = {
                    ["bitbake/requestEmbeddedLanguageDocInfos"] = function()
                        return opts.language
                    end,
                },
            }),
            filetypes = { "bitbake" },
        })
        vim.lsp.enable("user_bitbake")
        if opts.python ~= false then
            vim.lsp.config("user_python", {
                cmd = fake_cmd(python_messages, {
                    capabilities = { hoverProvider = true },
                    handlers = {
                        ["textDocument/hover"] = function()
                            return opts.hover
                        end,
                    },
                }),
                filetypes = { "python" },
            })
            vim.lsp.enable("user_python")
        end

        vim.bo[recipe_buf].filetype = "bitbake"
        yocto.handler(nil, { doc("python", table.concat(EMBEDDED, "\n"), INDEXES) }, {})
        local embedded_buf = vim.fn.bufnr(vim.uri_to_fname(yocto.get_embedded_uri(ORIG, "python")))
        vim.wait(1000, function()
            return proxy_client() ~= nil
                and #vim.lsp.get_clients({ bufnr = recipe_buf, name = "user_bitbake" }) == 1
                and (opts.python == false
                    or #vim.lsp.get_clients({ bufnr = embedded_buf, name = "user_python" }) == 1)
        end)
        return python_messages
    end

    local function hover(position)
        local response = proxy_client():request_sync(
            "textDocument/hover",
            { textDocument = { uri = ORIG }, position = position },
            1000,
            recipe_buf
        )
        return response and response.result
    end

    local function requests_for(messages, method)
        return vim.tbl_filter(function(m)
            return m.method == method
        end, messages)
    end

    it("advertises hover support", function()
        start_servers({ language = "python" })
        assert.is_true(proxy_client():supports_method("textDocument/hover"))
    end)

    it("forwards hover to the embedded server at the mapped position", function()
        local messages = start_servers({ language = "python", hover = { contents = "doc" } })
        hover(pos(0, 7))
        local requests = requests_for(messages, "textDocument/hover")
        assert.are.equal(1, #requests)
        assert.are.same({
            textDocument = { uri = yocto.get_embedded_uri(ORIG, "python") },
            position = pos(0, 4),
        }, requests[1].params)
    end)

    it("returns the hover contents of the embedded server", function()
        start_servers({ language = "python", hover = { contents = "doc" } })
        assert.are.same({ contents = "doc" }, hover(pos(0, 7)))
    end)

    it("maps the hover range back to the recipe", function()
        start_servers({
            language = "python",
            hover = { contents = "doc", range = { start = pos(0, 4), ["end"] = pos(0, 9) } },
        })
        assert.are.same(
            { contents = "doc", range = { start = pos(0, 7), ["end"] = pos(0, 12) } },
            hover(pos(0, 7))
        )
    end)

    it("drops a hover range that maps to generated text", function()
        start_servers({
            language = "python",
            hover = { contents = "doc", range = { start = pos(0, 0), ["end"] = pos(0, 3) } },
        })
        assert.are.same({ contents = "doc" }, hover(pos(0, 7)))
    end)

    it("does not forward when the bitbake server reports no language", function()
        local messages = start_servers({ language = nil, hover = { contents = "doc" } })
        assert.is_nil(hover(pos(0, 7)))
        assert.are.equal(0, #requests_for(messages, "textDocument/hover"))
    end)

    it("does not forward positions outside the character indexes", function()
        local messages = start_servers({ language = "python", hover = { contents = "doc" } })
        assert.is_nil(hover(pos(2, 1)))
        assert.are.equal(0, #requests_for(messages, "textDocument/hover"))
    end)

    it("returns nothing when no server is attached to the embedded doc", function()
        start_servers({ language = "python", python = false })
        assert.is_nil(hover(pos(0, 7)))
    end)

    it("attaches to bitbake buffers", function()
        vim.bo[recipe_buf].filetype = "bitbake"
        assert.is_true((vim.wait(1000, function()
            return proxy_client() ~= nil
        end)))
    end)

    it("does not attach to other buffers", function()
        vim.bo[recipe_buf].filetype = "sh"
        vim.wait(100)
        assert.is_nil(proxy_client())
    end)
end)

describe("default storage_dir", function()
    local original

    before_each(function()
        original = package.loaded["yocto"]
        package.loaded["yocto"] = nil
    end)

    after_each(function()
        package.loaded["yocto"] = original
    end)

    it("is inside the neovim session temp directory removed on exit", function()
        local session_tmp = vim.fs.dirname(vim.fn.tempname())
        local storage_dir = require("yocto").storage_dir
        assert.are.equal(session_tmp, vim.fs.dirname(storage_dir))
    end)
end)

describe("with real language servers", function()
    local yocto, dir, recipe_buf, recipe_uri

    local REAL_RECIPE = {
        'SUMMARY = "foo"',
        "do_install() {",
        "    echo hi",
        "}",
        "python do_foo() {",
        "    import os",
        "    os.getcwd()",
        "}",
    }

    local function proxy_hover(position)
        local proxy = vim.lsp.get_clients({ bufnr = recipe_buf, name = "yocto_embedded" })[1]
        local response = proxy:request_sync(
            "textDocument/hover",
            { textDocument = { uri = recipe_uri }, position = position },
            5000,
            recipe_buf
        )
        return response and response.result
    end

    -- Language servers may answer nothing until they finished indexing.
    local function eventual_hover(position)
        local result
        vim.wait(30000, function()
            result = proxy_hover(position)
            return result ~= nil
        end, 500)
        return result
    end

    before_each(function()
        yocto = require("yocto")
        yocto.storage_dir = vim.fn.tempname()
        dir = vim.fn.tempname()
        vim.fn.mkdir(dir, "p")
        local path = vim.fs.joinpath(dir, "foo_1.0.bb")
        vim.fn.writefile(REAL_RECIPE, path)
        recipe_uri = vim.uri_from_fname(path)
        recipe_buf = vim.fn.bufadd(path)
        vim.fn.bufload(recipe_buf)
        assert.are.equal("bitbake", vim.bo[recipe_buf].filetype)
        assert.is_true((vim.wait(30000, function()
            return yocto.get_embedded_uri(recipe_uri, "bash") ~= nil
                and yocto.get_embedded_uri(recipe_uri, "python") ~= nil
        end, 100)))
    end)

    after_each(function()
        stop_servers()
        remove_storage(yocto.storage_dir)
        vim.api.nvim_buf_delete(recipe_buf, { force = true })
        vim.fn.delete(dir, "rf")
    end)

    it("hovers bash code through bash-language-server", function()
        local result = eventual_hover(pos(2, 5))
        assert.is_not_nil(result)
        assert.is_not_nil(result.contents)
    end)

    it("hovers python code through pyright", function()
        local result = eventual_hover(pos(6, 5))
        assert.is_not_nil(result)
        assert.is_not_nil(result.contents)
    end)
end)

describe("bitbake project settings", function()
    local yocto, root, recipe_buf, messages

    -- Create files relative to the project root.
    local function write(relpath, lines)
        local path = vim.fs.joinpath(root, relpath)
        vim.fn.mkdir(vim.fs.dirname(path), "p")
        vim.fn.writefile(lines, path)
        return path
    end

    local function open_recipe()
        local path = write("sources/meta-foo/recipes-foo/foo/foo_1.0.bb", { 'SUMMARY = "foo"' })
        recipe_buf = vim.fn.bufadd(path)
        vim.fn.bufload(recipe_buf)
        vim.wait(1000, function()
            return #vim.tbl_filter(function(m)
                return m.method == "workspace/didChangeConfiguration"
            end, messages) > 0
        end)
    end

    local function sent(method)
        for _, m in ipairs(messages) do
            if m.method == method then
                return m.params
            end
        end
    end

    before_each(function()
        yocto = require("yocto")
        yocto.storage_dir = vim.fn.tempname()
        root = vim.fn.tempname()
        vim.fn.mkdir(root, "p")
        messages = {}
        vim.lsp.config("yocto_bitbake", { cmd = fake_cmd(messages) })
    end)

    after_each(function()
        stop_servers()
        vim.lsp.config.yocto_bitbake = {}
        yocto.register_defaults()
        remove_storage(yocto.storage_dir)
        if recipe_buf then
            vim.api.nvim_buf_delete(recipe_buf, { force = true })
        end
        vim.fn.delete(root, "rf")
    end)

    it("uses the directory containing sources as workspace folder", function()
        open_recipe()
        assert.are.equal(vim.uri_from_fname(root), sent("initialize").workspaceFolders[1].uri)
    end)

    it("prefers the directory containing .vscode as workspace folder", function()
        write("sources/.vscode/settings.json", { "{}" })
        open_recipe()
        assert.are.equal(
            vim.uri_from_fname(vim.fs.joinpath(root, "sources")),
            sent("initialize").workspaceFolders[1].uri
        )
    end)

    it("defaults pathToBitbakeFolder like the vscode extension", function()
        open_recipe()
        assert.are.equal(
            "${workspaceFolder}/sources/poky/bitbake",
            sent("workspace/didChangeConfiguration").settings.bitbake.pathToBitbakeFolder
        )
    end)

    it("sends bitbake settings from the project .vscode/settings.json", function()
        write(".vscode/settings.json", {
            "{",
            "  // comments and trailing commas are allowed by vscode",
            '  "bitbake.pathToBitbakeFolder": "${workspaceFolder}/poky/bitbake",',
            '  "bitbake.loggingLevel": "debug",',
            '  "editor.tabSize": 4,',
            "}",
        })
        open_recipe()
        local settings = sent("workspace/didChangeConfiguration").settings
        assert.are.same({
            pathToBitbakeFolder = "${workspaceFolder}/poky/bitbake",
            loggingLevel = "debug",
        }, settings.bitbake)
        assert.is_nil(settings.editor)
    end)

    it("accepts nested bitbake settings in .vscode/settings.json", function()
        write(".vscode/settings.json", { '{ "bitbake": { "pathToBitbakeFolder": "/opt/bitbake" } }' })
        open_recipe()
        assert.are.equal(
            "/opt/bitbake",
            sent("workspace/didChangeConfiguration").settings.bitbake.pathToBitbakeFolder
        )
    end)

    it("ignores an invalid .vscode/settings.json", function()
        write(".vscode/settings.json", { "{ not json" })
        open_recipe()
        assert.are.equal(
            "${workspaceFolder}/sources/poky/bitbake",
            sent("workspace/didChangeConfiguration").settings.bitbake.pathToBitbakeFolder
        )
    end)

    it("keeps settings from vim.lsp.config over the project file", function()
        vim.lsp.config("yocto_bitbake", { settings = { bitbake = { loggingLevel = "info" } } })
        write(".vscode/settings.json", { '{ "bitbake.loggingLevel": "debug" }' })
        open_recipe()
        assert.are.equal(
            "info",
            sent("workspace/didChangeConfiguration").settings.bitbake.loggingLevel
        )
    end)
end)
