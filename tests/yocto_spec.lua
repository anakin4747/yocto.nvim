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
        docs.cleanup()
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

    it("ignores unknown languages", function()
        docs.handler(nil, { doc("perl", "print 1") }, {})
        assert.is_nil(docs.get_embedded_uri(ORIG, "perl"))
        assert.are.equal(0, vim.fn.isdirectory(dir))
    end)

    it("does nothing when err is set", function()
        docs.handler({ code = -32603, message = "boom" }, { doc("bash", "a") }, {})
        assert.is_nil(docs.get_embedded_uri(ORIG, "bash"))
    end)

    it("cleanup removes storage_dir", function()
        docs.handler(nil, { doc("bash", "a") }, {})
        docs.cleanup()
        assert.are.equal(0, vim.fn.isdirectory(dir))
    end)

    it("cleanup forgets recorded docs", function()
        docs.handler(nil, { doc("bash", "a") }, {})
        docs.cleanup()
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
        yocto.cleanup()
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
        yocto.cleanup()
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

    it("cleanup wipes the embedded buffers", function()
        yocto.handler(nil, { doc("bash", "a"), doc("python", "b") }, {})
        local bash_buf, python_buf = embedded_buf("bash"), embedded_buf("python")
        yocto.cleanup()
        assert.is_false(vim.api.nvim_buf_is_valid(bash_buf))
        assert.is_false(vim.api.nvim_buf_is_valid(python_buf))
    end)

    it("cleanup closes the embedded doc in the language server", function()
        local messages = {}
        enable_user_server("sh", messages)
        yocto.handler(nil, { doc("bash", "echo hi") }, {})
        local uri = yocto.get_embedded_uri(ORIG, "bash")
        vim.wait(1000, function()
            return server_text(messages, uri) ~= nil
        end)
        yocto.cleanup()
        assert.is_true((vim.wait(1000, function()
            return server_text(messages, uri) == nil
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
        yocto.cleanup()
        vim.api.nvim_buf_delete(recipe_buf, { force = true })
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
