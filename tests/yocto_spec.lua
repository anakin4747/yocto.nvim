local describe = require("plenary.busted").describe
local it = require("plenary.busted").it
local before_each = require("plenary.busted").before_each
local after_each = require("plenary.busted").after_each
local yocto = require("yocto")

local ORIG = "file:///tmp/meta/recipes/foo/foo_1.0.bb"
local OTHER = "file:///tmp/meta/recipes/bar/bar_1.0.bb"

local function doc(lang, content, idx, orig)
    return {
        language = lang,
        content = content,
        characterIndexes = idx or {},
        originalUri = orig or ORIG,
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

local function readfile_from_uri(uri)
    return table.concat(vim.fn.readfile(vim.uri_to_fname(uri)), "\n")
end

describe("embedded language docs handler", function()
    local dir

    before_each(function()
        dir = vim.fn.tempname()
        yocto.storage_dir = dir
    end)

    after_each(function()
        remove_storage(yocto.storage_dir)
    end)

    it("writes a .sh file for a bash doc", function()
        yocto.handler(nil, { doc("bash", "echo hi") }, {})
        local uri = yocto.get_embedded_uri(ORIG, "bash")
        assert.is_not_nil(uri:match("%.sh$"))
        assert.are.equal("echo hi", readfile_from_uri(uri))
    end)

    it("writes a .py file for a python doc", function()
        yocto.handler(nil, { doc("python", "x = 1") }, {})
        local uri = yocto.get_embedded_uri(ORIG, "python")
        assert.is_not_nil(uri:match("%.py$"))
        assert.are.equal("x = 1", readfile_from_uri(uri))
    end)

    it("writes both files from a single notification", function()
        yocto.handler(nil, { doc("bash", "echo hi"), doc("python", "x = 1") }, {})
        assert.are.equal("echo hi", readfile_from_uri(yocto.get_embedded_uri(ORIG, "bash")))
        assert.are.equal("x = 1", readfile_from_uri(yocto.get_embedded_uri(ORIG, "python")))
    end)

    it("places files in the project directory of the recipe", function()
        yocto.handler(nil, { doc("bash", "echo hi") }, {})
        local path = vim.uri_to_fname(yocto.get_embedded_uri(ORIG, "bash"))
        assert.are.equal(yocto.project_dir(ORIG), vim.fs.dirname(path))
    end)

    it("names files with the sha256 of the original uri", function()
        yocto.handler(nil, { doc("bash", "echo hi") }, {})
        local path = vim.uri_to_fname(yocto.get_embedded_uri(ORIG, "bash"))
        assert.are.equal(vim.fn.sha256(ORIG) .. ".sh", vim.fs.basename(path))
    end)

    it("uses the same path for the same original uri", function()
        yocto.handler(nil, { doc("bash", "a") }, {})
        local first = yocto.get_embedded_uri(ORIG, "bash")
        yocto.handler(nil, { doc("bash", "b") }, {})
        assert.are.equal(first, yocto.get_embedded_uri(ORIG, "bash"))
    end)

    it("uses different paths for different original uris", function()
        yocto.handler(nil, { doc("bash", "a"), doc("bash", "b", {}, OTHER) }, {})
        assert.are_not.equal(
            yocto.get_embedded_uri(ORIG, "bash"),
            yocto.get_embedded_uri(OTHER, "bash")
        )
    end)

    it("overwrites content on a subsequent notification", function()
        yocto.handler(nil, { doc("bash", "old") }, {})
        yocto.handler(nil, { doc("bash", "new") }, {})
        assert.are.equal("new", readfile_from_uri(yocto.get_embedded_uri(ORIG, "bash")))
    end)

    it("reloads an already loaded buffer of the embedded file", function()
        yocto.handler(nil, { doc("bash", "old") }, {})
        local path = vim.uri_to_fname(yocto.get_embedded_uri(ORIG, "bash"))
        local bufnr = vim.fn.bufadd(path)
        vim.fn.bufload(bufnr)

        yocto.handler(nil, { doc("bash", "new") }, {})

        assert.are.same({ "new" }, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
        vim.api.nvim_buf_delete(bufnr, { force = true })
    end)

    it("records info for an embedded uri", function()
        yocto.handler(nil, { doc("python", "x", { 0, 1 }) }, {})
        local info = yocto.get_info(yocto.get_embedded_uri(ORIG, "python"))
        assert.are.same({
            original_uri = ORIG,
            language = "python",
            character_indexes = { 0, 1 },
        }, info)
    end)

    it("updates recorded character indexes on a subsequent notification", function()
        yocto.handler(nil, { doc("python", "x", { 0 }) }, {})
        yocto.handler(nil, { doc("python", "xy", { 0, 1 }) }, {})
        local info = yocto.get_info(yocto.get_embedded_uri(ORIG, "python"))
        assert.are.same({ 0, 1 }, info.character_indexes)
    end)

    it("returns nil info for an unknown embedded uri", function()
        assert.is_nil(yocto.get_info("file:///nowhere.sh"))
    end)

    it("returns nil embedded uri before any notification", function()
        assert.is_nil(yocto.get_embedded_uri(ORIG, "bash"))
    end)

    it("does nothing for an empty result", function()
        yocto.handler(nil, {}, {})
        assert.are.equal(0, vim.fn.isdirectory(dir))
    end)

    it("accepts docs wrapped in positional params as sent by the server", function()
        yocto.handler(nil, { { doc("bash", "echo hi"), doc("python", "x = 1") } }, {})
        assert.are.equal("echo hi", readfile_from_uri(yocto.get_embedded_uri(ORIG, "bash")))
        assert.are.equal("x = 1", readfile_from_uri(yocto.get_embedded_uri(ORIG, "python")))
    end)

    it("ignores unknown languages", function()
        yocto.handler(nil, { doc("perl", "print 1") }, {})
        assert.is_nil(yocto.get_embedded_uri(ORIG, "perl"))
        assert.are.equal(0, vim.fn.isdirectory(dir))
    end)

    it("does nothing when err is set", function()
        yocto.handler({ code = -32603, message = "boom" }, { doc("bash", "a") }, {})
        assert.is_nil(yocto.get_embedded_uri(ORIG, "bash"))
    end)

end)

local DEFAULT_NAMES = { "yocto_bitbake", "yocto_bash", "yocto_python" }

-- In-process fake language server. Records requests and notifications into
-- `messages`. `opts.handlers[method](params)` answers requests,
-- `opts.notifications[method](params, dispatchers)` reacts to notifications
-- and `opts.capabilities` extends the advertised capabilities.
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
                if opts.notifications and opts.notifications[method] then
                    vim.schedule(function()
                        opts.notifications[method](params, dispatchers)
                    end)
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
    vim.lsp.enable({ "user_server", "user_bitbake", "user_python", "user_bash", "user_zuban", unpack(DEFAULT_NAMES) }, false)
    for _, client in ipairs(vim.lsp.get_clients({ _uninitialized = true })) do
        client:stop(true)
    end
    vim.wait(500, function()
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
        assert.are.equal("echo hi", readfile_from_uri(yocto.get_embedded_uri(ORIG, "bash")))
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

describe("bitbake file scanning", function()
    local yocto = require("yocto")

    local function range(sl, sc, el, ec)
        return { start = pos(sl, sc), ["end"] = pos(el, ec) }
    end

    describe("find_function python", function()
        it("finds the name of a python def", function()
            local lines = { "X = '1'", "def foo(d):", "    pass" }
            assert.are.same({ range(1, 4, 1, 7) }, yocto.find_function(lines, "foo", "python"))
        end)

        it("finds the name of a python task", function()
            local lines = { "python foo () {", "}" }
            assert.are.same({ range(0, 7, 0, 10) }, yocto.find_function(lines, "foo", "python"))
        end)

        it("returns nothing when the function is absent", function()
            assert.are.same({}, yocto.find_function({ "def bar(d):" }, "foo", "python"))
        end)

        it("does not match a longer name", function()
            assert.are.same({}, yocto.find_function({ "def foo2(d):" }, "foo", "python"))
        end)
    end)

    describe("inherited_classes", function()
        it("lists every class of an inherit line with its position", function()
            assert.are.same({
                { name = "foo", position = pos(1, 8) },
                { name = "bar-baz", position = pos(1, 13) },
            }, yocto.inherited_classes({ "X = '1'", "inherit foo  bar-baz" }))
        end)

        it("lists classes of inherit_defer lines", function()
            assert.are.same(
                { { name = "foo", position = pos(0, 14) } },
                yocto.inherited_classes({ "inherit_defer foo" })
            )
        end)

        it("ignores lines that only start with inherit", function()
            assert.are.same({}, yocto.inherited_classes({ "inherited = 'foo'", "INHERIT += 'foo'" }))
        end)
    end)

    describe("find_function bash", function()
        it("finds shell function definitions", function()
            assert.are.same({
                range(0, 0, 0, 3),
                range(1, 0, 1, 3),
                range(2, 9, 2, 12),
                range(3, 7, 3, 10),
            }, yocto.find_function({ "foo() {", "foo () {", "fakeroot foo() {", "export foo() {" }, "foo", "bash"))
        end)

        it("does not mix up python and shell definitions", function()
            assert.are.same({}, yocto.find_function({ "python foo () {", "def foo(d):" }, "foo", "bash"))
            assert.are.same({}, yocto.find_function({ "foo() {" }, "foo", "python"))
        end)
    end)

    describe("function_doc bash", function()
        local function doc_of(lines)
            return yocto.function_doc(lines, yocto.find_function(lines, "foo", "bash")[1], "bash")
        end

        it("returns the signature and the comment block above it", function()
            assert.are.same(
                { signature = "foo() {", doc = "Does foo.\nOutput: logs" },
                doc_of({ "# License", "", "# Does foo.", "# Output: logs", "foo() {", "}" })
            )
        end)

        it("returns only the signature without an adjacent comment", function()
            assert.are.same({ signature = "foo() {" }, doc_of({ "# License", "", "foo() {", "}" }))
            assert.are.same({ signature = "foo() {" }, doc_of({ "foo() {", "}" }))
        end)

        it("returns the comment block at the top of the body", function()
            assert.are.same({
                signature = "foo () {",
                doc = "Create a wrapper.\n\nUseful for relocation.\n\nUsage: foo FILE",
            }, doc_of({
                "foo () {",
                "\t# Create a wrapper.",
                "\t#",
                "\t# Useful for relocation.",
                "\t#",
                "\t# Usage: foo FILE",
                "",
                "\tcmd=$1",
                "}",
            }))
        end)

        it("joins the comments above and at the top of the body", function()
            assert.are.same(
                { signature = "foo() {", doc = "Above.\n\nInside." },
                doc_of({ "# Above.", "foo() {", "\t# Inside.", "\ttrue", "}" })
            )
        end)

        it("ignores comments after code in the body", function()
            assert.are.same({ signature = "foo() {" }, doc_of({ "foo() {", "\ttrue", "\t# later", "}" }))
        end)
    end)

    describe("function_doc python", function()
        local function doc_of(lines, name)
            return yocto.function_doc(lines, yocto.find_function(lines, name, "python")[1], "python")
        end

        it("returns the signature and the dedented docstring", function()
            assert.are.same({
                signature = "def foo(d, x=None):",
                doc = "Split packages.\n\nArguments:\n  x -- a value",
            }, doc_of({
                "def foo(d, x=None):",
                '    """',
                "    Split packages.",
                "",
                "    Arguments:",
                "      x -- a value",
                '    """',
                "    pass",
            }, "foo"))
        end)

        it("joins a wrapped signature", function()
            assert.are.same(
                { signature = "def foo(d,\n        x):" },
                doc_of({ "def foo(d,", "        x):", "    pass" }, "foo")
            )
        end)

        it("reads one-line and single-quoted docstrings", function()
            assert.are.same(
                { signature = "def foo(d):", doc = "One line." },
                doc_of({ "def foo(d):", '    """One line."""' }, "foo")
            )
            assert.are.same(
                { signature = "def foo(d):", doc = "Quoted." },
                doc_of({ "def foo(d):", "    '''", "    Quoted.", "    '''" }, "foo")
            )
        end)

        it("returns only the signature without a docstring", function()
            assert.are.same({ signature = "def foo(d):" }, doc_of({ "def foo(d):", "    return 1" }, "foo"))
        end)
    end)

    describe("bblayers", function()
        it("lists the layers of a multi-line BBLAYERS with TOPDIR expanded", function()
            assert.are.same({ "/p/sources/poky/meta", "/abs/meta-x" }, yocto.bblayers({
                "# comment",
                'BBLAYERS ?= " \\',
                "  ${TOPDIR}/../sources/poky/meta \\",
                "  /abs/meta-x \\",
                '  "',
            }, "/p/build"))
        end)

        it("appends BBLAYERS += entries", function()
            assert.are.same(
                { "/a", "/b" },
                yocto.bblayers({ 'BBLAYERS = "/a"', 'BBLAYERS += "/b"' }, "/p/build")
            )
        end)

        it("expands variables of the same file and skips unknown ones", function()
            assert.are.same({ "/p/sources/meta-a" }, yocto.bblayers({
                'BSPDIR := "${TOPDIR}/../sources"',
                'BBLAYERS = "${BSPDIR}/meta-a ${OTHER}/meta-b ${@d.getVar(\'X\')}/meta-c"',
            }, "/p/build"))
        end)

        it("ignores other variables and returns nothing for an empty file", function()
            assert.are.same({}, yocto.bblayers({ 'BBPATH = "/x"', 'BBFILES ?= "/y"' }, "/p/build"))
            assert.are.same({}, yocto.bblayers({}, "/p/build"))
        end)
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
        assert.is_true((vim.wait(500, function()
            return server_text(messages, uri) == "echo hi\n"
        end)))
    end)

    it("opens the python doc in the language server enabled for python", function()
        local messages = {}
        enable_user_server("python", messages)
        yocto.handler(nil, { doc("python", "x = 1") }, {})
        local uri = yocto.get_embedded_uri(ORIG, "python")
        assert.is_true((vim.wait(500, function()
            return server_text(messages, uri) == "x = 1\n"
        end)))
    end)

    it("sends updated content to the language server", function()
        local messages = {}
        enable_user_server("sh", messages)
        yocto.handler(nil, { doc("bash", "old") }, {})
        local uri = yocto.get_embedded_uri(ORIG, "bash")
        vim.wait(500, function()
            return server_text(messages, uri) == "old\n"
        end)
        yocto.handler(nil, { doc("bash", "new") }, {})
        assert.is_true((vim.wait(500, function()
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

    local function range(sl, sc, el, ec)
        return { start = pos(sl, sc), ["end"] = pos(el, ec) }
    end

    -- Embedded language of the current test, set by start_servers.
    local embedded = "python"

    local function embedded_uri()
        return yocto.get_embedded_uri(ORIG, embedded)
    end

    -- Embedded doc fixtures: fake server, filetype, embedded lines, indexes.
    -- The bash recipe maps to its embedded doc unchanged.
    local BASH_RECIPE = { "do_install() {", "    oe_runmake", "}" }
    local BASH_INDEXES = {}
    for o = 0, #table.concat(BASH_RECIPE, "\n") do
        BASH_INDEXES[o + 1] = o
    end
    local FIXTURES = {
        python = { server = "user_python", filetype = "python", lines = EMBEDDED, indexes = INDEXES },
        bash = { server = "user_bash", filetype = "sh", lines = BASH_RECIPE, indexes = BASH_INDEXES },
    }

    local MAPPED = range(1, 4, 1, 9) -- same in recipe and embedded doc
    local HEADER = range(0, 4, 0, 9) -- embedded "do_foo", recipe (0, 7)-(0, 12)
    local GENERATED = range(0, 0, 0, 3) -- embedded "def", no recipe text
    local OS_URI = "file:///usr/lib/python3/os.py"

    -- Fake bitbake server reporting `language` everywhere, fake server for
    -- the `embedded` language (default python) answering hover with `hover`,
    -- and that language's fixture as embedded doc.
    local function start_servers(opts)
        local python_messages = {}
        embedded = opts.embedded or "python"
        local fixture = FIXTURES[embedded]
        if embedded == "bash" then
            vim.api.nvim_buf_set_lines(recipe_buf, 0, -1, false, BASH_RECIPE)
        end
        if opts.recipe then
            vim.api.nvim_buf_set_lines(recipe_buf, 0, -1, false, opts.recipe)
        end
        -- Assigned, not merged, so root and settings do not leak between tests.
        vim.lsp.config["user_bitbake"] = {
            cmd = fake_cmd(opts.bitbake_messages, {
                capabilities = { definitionProvider = true },
                handlers = vim.tbl_extend("force", {
                    ["bitbake/requestEmbeddedLanguageDocInfos"] = function()
                        return opts.language
                    end,
                }, opts.bitbake_handlers or {}),
            }),
            filetypes = { "bitbake" },
            root_dir = opts.bitbake_root,
            settings = opts.bitbake_settings,
        }
        vim.lsp.enable("user_bitbake")
        if opts.python ~= false then
            local handlers = {
                ["textDocument/hover"] = function()
                    return opts.hover
                end,
            }
            -- "EMBEDDED" in results stands for the embedded doc uri.
            local function substitute(value)
                if value == "EMBEDDED" then
                    return embedded_uri()
                elseif type(value) == "table" then
                    local copy = {}
                    for k, v in pairs(value) do
                        copy[substitute(k)] = substitute(v)
                    end
                    return copy
                end
                return value
            end
            for method, result in pairs(opts.results or {}) do
                handlers[method] = function()
                    return substitute(result)
                end
            end
            -- Publish opts.diagnostics[n] for the n-th version of the doc.
            local published = 0
            local function publish(params, dispatchers)
                published = published + 1
                local diagnostics = opts.diagnostics and opts.diagnostics[published]
                if diagnostics then
                    dispatchers.notification("textDocument/publishDiagnostics", {
                        uri = params.textDocument.uri,
                        diagnostics = diagnostics,
                    })
                end
            end
            vim.lsp.config[fixture.server] = {
                cmd = fake_cmd(python_messages, {
                    capabilities = vim.tbl_extend("force", { hoverProvider = true }, opts.capabilities or {}),
                    handlers = handlers,
                    notifications = {
                        ["textDocument/didOpen"] = publish,
                        ["textDocument/didChange"] = publish,
                    },
                }),
                filetypes = { fixture.filetype },
            }
            vim.lsp.enable(fixture.server)
        end

        vim.bo[recipe_buf].filetype = "bitbake"
        yocto.handler(nil, { doc(embedded, table.concat(fixture.lines, "\n"), fixture.indexes) }, {})
        local embedded_buf = vim.fn.bufnr(vim.uri_to_fname(embedded_uri()))
        vim.wait(500, function()
            return proxy_client() ~= nil
                and #vim.lsp.get_clients({ bufnr = recipe_buf, name = "user_bitbake" }) == 1
                and (opts.python == false
                    or #vim.lsp.get_clients({ bufnr = embedded_buf, name = fixture.server }) == 1)
        end)
        return python_messages
    end

    local function hover(position)
        local response = proxy_client():request_sync(
            "textDocument/hover",
            { textDocument = { uri = ORIG }, position = position },
            500,
            recipe_buf
        )
        return response and response.result
    end

    -- Send method at position on the recipe through the proxy.
    local function request(method, position, extra)
        local params = vim.tbl_extend("force", { textDocument = { uri = ORIG }, position = position }, extra or {})
        local response = proxy_client():request_sync(method, params, 500, recipe_buf)
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

    it("asks the bitbake server, not other clients on the recipe, for the language", function()
        -- Like GitHub Copilot: attached to every buffer, started first.
        vim.lsp.start({ name = "other", cmd = fake_cmd() }, { bufnr = recipe_buf })
        start_servers({ language = "python", hover = { contents = "doc" } })
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

    describe("definition", function()
        local METHODS = {
            "textDocument/definition",
            "textDocument/declaration",
            "textDocument/typeDefinition",
            "textDocument/implementation",
        }

        for _, method in ipairs(METHODS) do
            it("advertises and forwards " .. method, function()
                local messages = start_servers({
                    language = "python",
                    capabilities = {
                        definitionProvider = true,
                        declarationProvider = true,
                        typeDefinitionProvider = true,
                        implementationProvider = true,
                    },
                    results = { [method] = { { uri = "EMBEDDED", range = MAPPED } } },
                })
                assert.is_true(proxy_client():supports_method(method))
                request(method, pos(0, 7))
                local requests = requests_for(messages, method)
                assert.are.equal(1, #requests)
                assert.are.same(pos(0, 4), requests[1].params.position)
            end)
        end

        local function definition(result)
            start_servers({
                language = "python",
                capabilities = { definitionProvider = true },
                results = { ["textDocument/definition"] = result },
            })
            return request("textDocument/definition", pos(1, 4))
        end

        it("maps a location in the embedded doc back to the recipe", function()
            local result = definition({ uri = "EMBEDDED", range = MAPPED })
            assert.are.same({ uri = ORIG, range = MAPPED }, result)
        end)

        it("maps a list of locations", function()
            local result = definition({
                { uri = "EMBEDDED", range = HEADER },
                { uri = OS_URI, range = range(3, 0, 3, 5) },
            })
            assert.are.same({
                { uri = ORIG, range = range(0, 7, 0, 12) },
                { uri = OS_URI, range = range(3, 0, 3, 5) },
            }, result)
        end)

        it("returns nil when all locations are in generated text", function()
            local result = definition({ { uri = "EMBEDDED", range = GENERATED } })
            assert.is_nil(result)
        end)

        it("maps location links", function()
            local result = definition({
                {
                    targetUri = "EMBEDDED",
                    targetRange = MAPPED,
                    targetSelectionRange = HEADER,
                    originSelectionRange = MAPPED,
                },
            })
            assert.are.same({
                {
                    targetUri = ORIG,
                    targetRange = MAPPED,
                    targetSelectionRange = range(0, 7, 0, 12),
                    originSelectionRange = MAPPED,
                },
            }, result)
        end)
    end)

    describe("definition in inherited classes", function()
        -- Recipe lines 0-2 are the do_foo fixture; "x" at (1, 4) is the word.
        local INHERITING = { RECIPE[1], RECIPE[2], RECIPE[3], "inherit foo" }
        local layer, bitbake_messages

        before_each(function()
            layer = vim.fn.tempname()
            bitbake_messages = {}
        end)

        after_each(function()
            vim.fn.delete(layer, "rf")
        end)

        -- Write a class file under the layer and return its uri.
        local function write_class(dir, name, lines)
            vim.fn.mkdir(layer .. "/" .. dir, "p")
            local path = layer .. "/" .. dir .. "/" .. name .. ".bbclass"
            vim.fn.writefile(lines, path)
            return vim.uri_from_fname(path)
        end

        -- The fake bitbake server resolves the class at `inherit foo` to foo_uri.
        local function definition(opts)
            start_servers(vim.tbl_extend("force", {
                language = "python",
                recipe = INHERITING,
                bitbake_messages = bitbake_messages,
                capabilities = { definitionProvider = true },
                results = { ["textDocument/definition"] = {} },
                bitbake_handlers = {
                    ["textDocument/definition"] = function(params)
                        if params.position.line == 3 and params.position.character == 8 and opts.foo_uri then
                            return { { uri = opts.foo_uri, range = range(0, 0, 0, 0) } }
                        end
                        return {}
                    end,
                },
            }, opts))
            return request(opts.method or "textDocument/definition", pos(1, 4))
        end

        it("finds a python function defined in an inherited class", function()
            local foo_uri = write_class("classes-recipe", "foo", { "X = '1'", "def x(d):", "    pass" })
            assert.are.same({ { uri = foo_uri, range = range(1, 4, 1, 5) } }, definition({ foo_uri = foo_uri }))
        end)

        it("does not search classes when the python server finds the definition", function()
            local foo_uri = write_class("classes-recipe", "foo", { "def x(d):" })
            local result = definition({
                foo_uri = foo_uri,
                results = { ["textDocument/definition"] = { uri = "EMBEDDED", range = MAPPED } },
            })
            assert.are.same({ uri = ORIG, range = MAPPED }, result)
            assert.are.equal(0, #requests_for(bitbake_messages, "textDocument/definition"))
        end)

        it("returns nil when no inherited class defines the function", function()
            local foo_uri = write_class("classes-recipe", "foo", { "def y(d):" })
            assert.is_nil(definition({ foo_uri = foo_uri }))
        end)

        it("finds a python function in a class inherited by an inherited class", function()
            local foo_uri = write_class("classes-recipe", "foo", { "inherit bar" })
            local bar_uri = write_class("classes", "bar", { "def x(d):" })
            assert.are.same({ { uri = bar_uri, range = range(0, 4, 0, 5) } }, definition({ foo_uri = foo_uri }))
        end)

        it("stops at classes that inherit each other", function()
            local foo_uri = write_class("classes-recipe", "foo", { "inherit bar" })
            write_class("classes-global", "bar", { "inherit foo" })
            assert.is_nil(definition({ foo_uri = foo_uri }))
        end)

        describe("hover", function()
            local ANY = { contents = { kind = "markdown", value = "```python\nx: Any\n```" } }

            local function class_hover(opts)
                return definition(vim.tbl_extend("force", { method = "textDocument/hover", hover = ANY }, opts))
            end

            it("shows the signature and docstring of a function defined in a class", function()
                local foo_uri = write_class("classes-recipe", "foo", {
                    "def x(d, y=None):",
                    '    """',
                    "    Does x.",
                    '    """',
                })
                assert.are.same({
                    contents = {
                        kind = "markdown",
                        value = "```python\ndef x(d, y=None):\n```\n\nDoes x.\n\n*foo.bbclass:1*",
                    },
                }, class_hover({ foo_uri = foo_uri }))
            end)

            it("keeps a python hover with content and does not search classes", function()
                local foo_uri = write_class("classes-recipe", "foo", { "def x(d):" })
                local own = { contents = { kind = "markdown", value = "```python\ndef x() -> int\n```\nDoc" } }
                assert.are.same(own, class_hover({ foo_uri = foo_uri, hover = own }))
                assert.are.equal(0, #requests_for(bitbake_messages, "textDocument/definition"))
            end)

            it("keeps the python hover when no class defines the function", function()
                local foo_uri = write_class("classes-recipe", "foo", { "def y(d):" })
                assert.are.same(ANY, class_hover({ foo_uri = foo_uri }))
            end)
        end)

        describe("bash", function()
            -- Recipe lines 0-2 are the do_install fixture; "oe_runmake" at (1, 4).
            local function bash(opts)
                return definition(vim.tbl_extend("force", {
                    embedded = "bash",
                    language = "bash",
                    recipe = { "do_install() {", "    oe_runmake", "}", "inherit foo" },
                    hover = vim.NIL,
                }, opts))
            end

            it("finds a shell function defined in a class", function()
                local foo_uri = write_class("classes-recipe", "foo", { "oe_runmake() {", "}" })
                assert.are.same({ { uri = foo_uri, range = range(0, 0, 0, 10) } }, bash({ foo_uri = foo_uri }))
            end)

            it("shows the signature, comment and location of a shell function", function()
                local foo_uri = write_class("classes-recipe", "foo", { "# Runs make.", "oe_runmake() {", "}" })
                assert.are.same({
                    contents = { kind = "markdown", value = "```sh\noe_runmake() {\n```\n\nRuns make.\n\n*foo.bbclass:2*" },
                }, bash({ foo_uri = foo_uri, method = "textDocument/hover" }))
            end)

            it("keeps a bash hover with content and does not search classes", function()
                local foo_uri = write_class("classes-recipe", "foo", { "oe_runmake() {", "}" })
                local own = { contents = { kind = "markdown", value = "man page" } }
                assert.are.same(own, bash({ foo_uri = foo_uri, hover = own, method = "textDocument/hover" }))
                assert.are.equal(0, #requests_for(bitbake_messages, "textDocument/definition"))
            end)
        end)

        describe("with a bblayers.conf", function()
            -- `layer` is the project root; its build lists meta-a and meta-b.
            local function write_bblayers(build)
                vim.fn.mkdir(layer .. "/" .. build .. "/conf", "p")
                vim.fn.writefile({
                    'BBLAYERS ?= " \\',
                    "  ${TOPDIR}/../meta-a \\",
                    "  ${TOPDIR}/../meta-b \\",
                    '  "',
                }, layer .. "/" .. build .. "/conf/bblayers.conf")
            end

            local function global_definition(opts)
                return definition(vim.tbl_extend("force", { recipe = RECIPE, bitbake_root = layer }, opts or {}))
            end

            it("finds a python function in a global class without inherit lines", function()
                write_bblayers("build")
                local g_uri = write_class("meta-b/classes-global", "g", { "def x(d):" })
                assert.are.same({ { uri = g_uri, range = range(0, 4, 0, 5) } }, global_definition())
            end)

            it("finds the build folder above a client rooted in a layer repository", function()
                write_bblayers("build")
                vim.fn.mkdir(layer .. "/sources/openembedded-core/.git", "p")
                local g_uri = write_class("meta-b/classes-global", "g", { "def x(d):" })
                assert.are.same(
                    { { uri = g_uri, range = range(0, 4, 0, 5) } },
                    global_definition({ bitbake_root = layer .. "/sources/openembedded-core" })
                )
            end)

            it("uses pathToBuildFolder from the bitbake settings", function()
                write_bblayers("out")
                local g_uri = write_class("meta-a/classes-global", "g", { "def x(d):" })
                assert.are.same(
                    { { uri = g_uri, range = range(0, 4, 0, 5) } },
                    global_definition({
                        bitbake_settings = { bitbake = { pathToBuildFolder = "${workspaceFolder}/out" } },
                    })
                )
            end)

            it("lists inherited classes before global classes", function()
                write_bblayers("build")
                local foo_uri = write_class("meta-a/classes-recipe", "foo", { "def x(d):" })
                local g_uri = write_class("meta-a/classes-global", "g", { "def x(d):" })
                assert.are.same({
                    { uri = foo_uri, range = range(0, 4, 0, 5) },
                    { uri = g_uri, range = range(0, 4, 0, 5) },
                }, global_definition({ recipe = INHERITING, foo_uri = foo_uri }))
            end)

            it("follows inherits of global classes into other layers", function()
                write_bblayers("build")
                write_class("meta-a/classes-global", "g", { "inherit h" })
                local h_uri = write_class("meta-b/classes", "h", { "def x(d):" })
                assert.are.same({ { uri = h_uri, range = range(0, 4, 0, 5) } }, global_definition())
            end)
        end)

        it("does not search classes for references", function()
            write_class("classes-recipe", "foo", { "def x(d):" })
            start_servers({
                language = "python",
                recipe = INHERITING,
                bitbake_messages = bitbake_messages,
                capabilities = { referencesProvider = true },
                results = { ["textDocument/references"] = {} },
            })
            local result = request("textDocument/references", pos(1, 4), { context = { includeDeclaration = true } })
            assert.are.same({}, result)
            assert.are.equal(0, #requests_for(bitbake_messages, "textDocument/definition"))
        end)
    end)

    -- Start servers where the python server answers method with result, and
    -- send method through the proxy at a mapped recipe position.
    local function forwarded(method, capability, result, extra)
        local messages = start_servers({
            language = "python",
            capabilities = capability,
            results = { [method] = result },
        })
        return request(method, pos(1, 4), extra), requests_for(messages, method)
    end

    describe("references", function()
        it("passes the reference context through", function()
            local _, requests = forwarded(
                "textDocument/references",
                { referencesProvider = true },
                {},
                { context = { includeDeclaration = true } }
            )
            assert.are.same({ includeDeclaration = true }, requests[1].params.context)
        end)

        it("maps and drops locations", function()
            local result = forwarded("textDocument/references", { referencesProvider = true }, {
                { uri = "EMBEDDED", range = MAPPED },
                { uri = "EMBEDDED", range = GENERATED },
                { uri = OS_URI, range = MAPPED },
            }, { context = { includeDeclaration = true } })
            assert.are.same({ { uri = ORIG, range = MAPPED }, { uri = OS_URI, range = MAPPED } }, result)
        end)
    end)

    describe("document highlight", function()
        it("maps and drops highlights", function()
            local result = forwarded("textDocument/documentHighlight", { documentHighlightProvider = true }, {
                { range = HEADER, kind = 1 },
                { range = GENERATED, kind = 1 },
            })
            assert.are.same({ { range = range(0, 7, 0, 12), kind = 1 } }, result)
        end)
    end)

    describe("completion", function()
        local CAPABILITY = { completionProvider = {} }

        it("advertises completion with trigger characters", function()
            start_servers({ language = "python" })
            assert.is_true(proxy_client():supports_method("textDocument/completion"))
            assert.is_true(vim.list_contains(
                proxy_client().server_capabilities.completionProvider.triggerCharacters,
                "."
            ))
        end)

        it("keeps items without edits", function()
            local result = forwarded("textDocument/completion", CAPABILITY, { { label = "getcwd" } })
            assert.are.same({ { label = "getcwd" } }, result)
        end)

        it("maps text edit ranges of a completion list", function()
            local result = forwarded("textDocument/completion", CAPABILITY, {
                isIncomplete = true,
                items = {
                    { label = "do_foo", textEdit = { range = HEADER, newText = "do_foo" } },
                },
            })
            assert.are.same({
                isIncomplete = true,
                items = {
                    { label = "do_foo", textEdit = { range = range(0, 7, 0, 12), newText = "do_foo" } },
                },
            }, result)
        end)

        it("maps insert and replace edits", function()
            local result = forwarded("textDocument/completion", CAPABILITY, {
                { label = "x", textEdit = { insert = MAPPED, replace = HEADER, newText = "x" } },
            })
            assert.are.same({
                { label = "x", textEdit = { insert = MAPPED, replace = range(0, 7, 0, 12), newText = "x" } },
            }, result)
        end)

        it("drops items editing generated text", function()
            local result = forwarded("textDocument/completion", CAPABILITY, {
                { label = "bad", textEdit = { range = GENERATED, newText = "bad" } },
                { label = "bad_extra", additionalTextEdits = { { range = GENERATED, newText = "import x" } } },
                { label = "good", additionalTextEdits = { { range = MAPPED, newText = "y" } } },
            })
            assert.are.same({
                { label = "good", additionalTextEdits = { { range = MAPPED, newText = "y" } } },
            }, result)
        end)
    end)

    describe("rename", function()
        it("advertises rename with prepare support", function()
            start_servers({ language = "python" })
            assert.is_true(proxy_client():supports_method("textDocument/rename"))
            assert.is_true(proxy_client():supports_method("textDocument/prepareRename"))
        end)

        it("maps workspace edit changes back to the recipe", function()
            local result = forwarded("textDocument/rename", { renameProvider = true }, {
                changes = {
                    EMBEDDED = {
                        { range = MAPPED, newText = "y" },
                        { range = GENERATED, newText = "y" },
                    },
                    [OS_URI] = { { range = MAPPED, newText = "y" } },
                },
            }, { newName = "y" })
            assert.are.same({
                changes = {
                    [ORIG] = { { range = MAPPED, newText = "y" } },
                    [OS_URI] = { { range = MAPPED, newText = "y" } },
                },
            }, result)
        end)

        it("maps document changes back to the recipe", function()
            local result = forwarded("textDocument/rename", { renameProvider = true }, {
                documentChanges = {
                    { textDocument = { uri = "EMBEDDED", version = 3 }, edits = { { range = HEADER, newText = "y" } } },
                },
            }, { newName = "y" })
            assert.are.same({ changes = { [ORIG] = { { range = range(0, 7, 0, 12), newText = "y" } } } }, result)
        end)

        it("maps a prepareRename range", function()
            local result = forwarded("textDocument/prepareRename", { renameProvider = { prepareProvider = true } }, HEADER)
            assert.are.same(range(0, 7, 0, 12), result)
        end)

        it("maps a prepareRename range with placeholder", function()
            local result = forwarded(
                "textDocument/prepareRename",
                { renameProvider = { prepareProvider = true } },
                { range = MAPPED, placeholder = "x" }
            )
            assert.are.same({ range = MAPPED, placeholder = "x" }, result)
        end)

        it("refuses prepareRename in generated text", function()
            local result =
                forwarded("textDocument/prepareRename", { renameProvider = { prepareProvider = true } }, GENERATED)
            assert.is_nil(result)
        end)
    end)

    describe("signature help", function()
        it("forwards signature help unchanged", function()
            local help = { signatures = { { label = "getcwd()" } }, activeSignature = 0 }
            local result = forwarded("textDocument/signatureHelp", { signatureHelpProvider = {} }, help)
            assert.are.same(help, result)
        end)
    end)

    describe("diagnostics", function()
        local function lsp_diagnostic(r, message)
            return { range = r, message = message, severity = 2, source = "fake" }
        end

        local function recipe_diagnostics(count)
            vim.wait(500, function()
                return #vim.diagnostic.get(recipe_buf) == count
            end, 10)
            return vim.diagnostic.get(recipe_buf)
        end

        it("shows embedded diagnostics on the recipe at the mapped range", function()
            start_servers({ language = "python", diagnostics = { { lsp_diagnostic(HEADER, "bad name") } } })
            local diagnostics = recipe_diagnostics(1)
            assert.are.equal(1, #diagnostics)
            assert.are.same(
                { lnum = 0, col = 7, end_lnum = 0, end_col = 12, message = "bad name", severity = 2, source = "fake" },
                {
                    lnum = diagnostics[1].lnum,
                    col = diagnostics[1].col,
                    end_lnum = diagnostics[1].end_lnum,
                    end_col = diagnostics[1].end_col,
                    message = diagnostics[1].message,
                    severity = diagnostics[1].severity,
                    source = diagnostics[1].source,
                }
            )
        end)

        it("drops diagnostics in generated text", function()
            start_servers({
                language = "python",
                diagnostics = { { lsp_diagnostic(GENERATED, "header"), lsp_diagnostic(MAPPED, "body") } },
            })
            local diagnostics = recipe_diagnostics(1)
            assert.are.equal(1, #diagnostics)
            assert.are.equal("body", diagnostics[1].message)
        end)

        it("clears recipe diagnostics when the embedded ones are cleared", function()
            start_servers({ language = "python", diagnostics = { { lsp_diagnostic(MAPPED, "body") }, {} } })
            recipe_diagnostics(1)
            yocto.handler(nil, { doc("python", table.concat(EMBEDDED, "\n"), INDEXES) }, {})
            assert.are.equal(0, #recipe_diagnostics(0))
        end)
    end)

    it("attaches to bitbake buffers", function()
        vim.bo[recipe_buf].filetype = "bitbake"
        assert.is_true((vim.wait(500, function()
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
            500,
            recipe_buf
        )
        return response and response.result
    end

    -- Language servers may answer nothing until they finished indexing.
    local function eventual_hover(position)
        local result
        vim.wait(500, function()
            result = proxy_hover(position)
            return result ~= nil
        end, 50)
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
        -- zubanls starts much faster than pyright.
        vim.lsp.config("user_python", { cmd = { "zuban", "server" }, filetypes = { "python" } })
        vim.lsp.enable("user_python")
        vim.fn.bufload(recipe_buf)
        assert.are.equal("bitbake", vim.bo[recipe_buf].filetype)
        assert.is_true((vim.wait(500, function()
            return yocto.get_embedded_uri(recipe_uri, "bash") ~= nil
                and yocto.get_embedded_uri(recipe_uri, "python") ~= nil
        end, 10)))
    end)

    after_each(function()
        stop_servers()
        vim.lsp.config.user_python = {}
        remove_storage(yocto.storage_dir)
        vim.api.nvim_buf_delete(recipe_buf, { force = true })
        vim.fn.delete(dir, "rf")
    end)

    it("hovers bash code through bash-language-server", function()
        local result = eventual_hover(pos(2, 5))
        assert.is_not_nil(result)
        assert.is_not_nil(result.contents)
    end)

    it("hovers python code through zubanls", function()
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
        vim.wait(500, function()
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

-- Build a temporary directory tree; returns its root and a writer for it.
local function temp_tree()
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, "p")
    return root, function(relpath, lines)
        local path = vim.fs.joinpath(root, relpath)
        vim.fn.mkdir(vim.fs.dirname(path), "p")
        vim.fn.writefile(lines or {}, path)
        return path
    end
end

describe("project_root", function()
    local yocto = require("yocto")
    local root, write

    before_each(function()
        root, write = temp_tree()
    end)

    after_each(function()
        vim.fn.delete(root, "rf")
    end)

    for _, marker in ipairs({ ".vscode", "sources", "layers", "build" }) do
        it("finds the directory containing " .. marker, function()
            vim.fn.mkdir(vim.fs.joinpath(root, marker), "p")
            local recipe = write("meta-foo/recipes-foo/foo/foo_1.0.bb")
            assert.are.equal(root, yocto.project_root(recipe))
        end)
    end

    it("uses the nearest directory containing any marker", function()
        vim.fn.mkdir(vim.fs.joinpath(root, "sources"), "p")
        vim.fn.mkdir(vim.fs.joinpath(root, "poky", "build"), "p")
        local recipe = write("poky/meta/recipes-foo/foo/foo_1.0.bb")
        assert.are.equal(vim.fs.joinpath(root, "poky"), yocto.project_root(recipe))
    end)

    it("returns nil outside a project", function()
        assert.is_nil(yocto.project_root(write("foo_1.0.bb")))
    end)
end)

describe("bitbake_python_paths", function()
    local yocto = require("yocto")
    local root, write

    local function bitbake_at(dir)
        write(dir .. "/lib/bb/__init__.py")
    end

    local function oe_at(dir)
        write(dir .. "/lib/oe/__init__.py")
    end

    local function abs(relpath)
        return vim.fs.joinpath(root, relpath)
    end

    before_each(function()
        root, write = temp_tree()
    end)

    after_each(function()
        vim.fn.delete(root, "rf")
    end)

    for _, prefix in ipairs({ "sources", "layers" }) do
        it("finds poky under " .. prefix, function()
            bitbake_at(prefix .. "/poky/bitbake")
            oe_at(prefix .. "/poky/meta")
            assert.are.same(
                { abs(prefix .. "/poky/bitbake/lib"), abs(prefix .. "/poky/meta/lib") },
                yocto.bitbake_python_paths(root)
            )
        end)

        it("finds separate bitbake and openembedded-core under " .. prefix, function()
            bitbake_at(prefix .. "/bitbake")
            oe_at(prefix .. "/openembedded-core/meta")
            assert.are.same(
                { abs(prefix .. "/bitbake/lib"), abs(prefix .. "/openembedded-core/meta/lib") },
                yocto.bitbake_python_paths(root)
            )
        end)
    end

    it("finds bitbake when the project root is poky itself", function()
        bitbake_at("bitbake")
        oe_at("meta")
        assert.are.same({ abs("bitbake/lib"), abs("meta/lib") }, yocto.bitbake_python_paths(root))
    end)

    it("uses pathToBitbakeFolder from .vscode/settings.json", function()
        bitbake_at("sources/poky/bitbake")
        bitbake_at("tools/bitbake")
        oe_at("tools/meta")
        write(".vscode/settings.json", {
            '{ "bitbake.pathToBitbakeFolder": "${workspaceFolder}/tools/bitbake" }',
        })
        assert.are.same({ abs("tools/bitbake/lib"), abs("tools/meta/lib") }, yocto.bitbake_python_paths(root))
    end)

    it("returns only bitbake when oe is not found", function()
        bitbake_at("sources/poky/bitbake")
        assert.are.same({ abs("sources/poky/bitbake/lib") }, yocto.bitbake_python_paths(root))
    end)

    it("returns nothing when bitbake is not found", function()
        oe_at("sources/poky/meta")
        assert.are.same({}, yocto.bitbake_python_paths(root))
    end)

    it("returns nothing without a project root", function()
        assert.are.same({}, yocto.bitbake_python_paths(nil))
    end)
end)

describe("project_dir", function()
    local yocto = require("yocto")
    local root, write

    before_each(function()
        yocto.storage_dir = vim.fn.tempname()
        root, write = temp_tree()
        vim.fn.mkdir(vim.fs.joinpath(root, "a", "sources"), "p")
        vim.fn.mkdir(vim.fs.joinpath(root, "b", "sources"), "p")
    end)

    after_each(function()
        vim.fn.delete(root, "rf")
    end)

    local function uri(relpath)
        return vim.uri_from_fname(write(relpath))
    end

    it("is inside storage_dir", function()
        assert.are.equal(yocto.storage_dir, vim.fs.dirname(yocto.project_dir(uri("a/sources/meta/foo.bb"))))
    end)

    it("is shared by recipes of the same project", function()
        assert.are.equal(
            yocto.project_dir(uri("a/sources/meta-x/foo.bb")),
            yocto.project_dir(uri("a/sources/meta-y/bar.bb"))
        )
    end)

    it("differs between projects", function()
        assert.are_not.equal(
            yocto.project_dir(uri("a/sources/meta/foo.bb")),
            yocto.project_dir(uri("b/sources/meta/foo.bb"))
        )
    end)

    it("is shared by recipes outside any project", function()
        assert.are.equal(yocto.project_dir(uri("x/foo.bb")), yocto.project_dir(uri("y/bar.bb")))
    end)
end)

describe("embedded python servers", function()
    local yocto, root, write, messages

    local function setup_project(name)
        write(name .. "/sources/poky/bitbake/lib/bb/__init__.py")
        write(name .. "/sources/poky/meta/lib/oe/__init__.py")
        return vim.uri_from_fname(write(name .. "/sources/meta-foo/recipes-foo/foo/foo_1.0.bb"))
    end

    local function python_paths(name)
        return {
            vim.fs.joinpath(root, name, "sources/poky/bitbake/lib"),
            vim.fs.joinpath(root, name, "sources/poky/meta/lib"),
        }
    end

    local function enable_user_python(extra)
        vim.lsp.config("user_python", vim.tbl_extend("force", {
            cmd = fake_cmd(messages),
            filetypes = { "python" },
            root_markers = { ".git" },
        }, extra or {}))
        vim.lsp.enable("user_python")
    end

    -- Send a python doc for recipe_uri and return the started user client.
    local function open_python_doc(recipe_uri)
        yocto.handler(nil, { doc("python", "x = 1", {}, recipe_uri) }, {})
        local bufnr = vim.fn.bufnr(vim.uri_to_fname(yocto.get_embedded_uri(recipe_uri, "python")))
        local client
        vim.wait(500, function()
            client = vim.lsp.get_clients({ bufnr = bufnr, name = "user_python" })[1]
            return client ~= nil
        end)
        return client, bufnr
    end

    before_each(function()
        yocto = require("yocto")
        yocto.storage_dir = vim.fn.tempname()
        root, write = temp_tree()
        messages = {}
    end)

    after_each(function()
        stop_servers()
        vim.lsp.config.user_python = {}
        remove_storage(yocto.storage_dir)
        vim.fn.delete(root, "rf")
    end)

    it("keeps embedded python buffers out of automatic lsp attachment", function()
        enable_user_python()
        local _, bufnr = open_python_doc(setup_project("a"))
        assert.are.equal("nowrite", vim.bo[bufnr].buftype)
    end)

    it("starts the enabled python server with the project directory as root", function()
        enable_user_python()
        local recipe = setup_project("a")
        local client = open_python_doc(recipe)
        assert.are.equal(yocto.project_dir(recipe), client.root_dir)
        vim.wait(500, function()
            return #messages > 0
        end)
        assert.are.equal(vim.uri_from_fname(yocto.project_dir(recipe)), messages[1].params.workspaceFolders[1].uri)
    end)

    it("gives pyright and basedpyright the bitbake python paths", function()
        enable_user_python()
        local client = open_python_doc(setup_project("a"))
        assert.are.same(python_paths("a"), client.settings.python.analysis.extraPaths)
        assert.are.same(python_paths("a"), client.settings.basedpyright.analysis.extraPaths)
    end)

    it("gives zubanls and others the bitbake python paths in the environment", function()
        enable_user_python()
        local client = open_python_doc(setup_project("a"))
        local joined = table.concat(python_paths("a"), ":")
        assert.are.equal(joined, client.config.cmd_env.MYPYPATH)
        assert.are.equal(joined, client.config.cmd_env.PYTHONPATH)
    end)

    it("keeps the user's own settings and environment", function()
        enable_user_python({
            settings = { python = { analysis = { extraPaths = { "/mine" }, typeCheckingMode = "off" } } },
            cmd_env = { FOO = "1" },
        })
        local client = open_python_doc(setup_project("a"))
        assert.are.same(
            { "/mine", unpack(python_paths("a")) },
            client.settings.python.analysis.extraPaths
        )
        assert.are.equal("off", client.settings.python.analysis.typeCheckingMode)
        assert.are.equal("1", client.config.cmd_env.FOO)
    end)

    it("starts one python server per project", function()
        enable_user_python()
        local client_a = open_python_doc(setup_project("a"))
        local client_b = open_python_doc(setup_project("b"))
        assert.are_not.equal(client_a.id, client_b.id)
        assert.are.same(python_paths("b"), client_b.settings.python.analysis.extraPaths)
    end)

    it("reuses the python server for recipes of the same project", function()
        enable_user_python()
        local recipe = setup_project("a")
        local client_a = open_python_doc(recipe)
        local other = vim.uri_from_fname(write("a/sources/meta-foo/recipes-foo/bar/bar_1.0.bb"))
        local client_b = open_python_doc(other)
        assert.are.equal(client_a.id, client_b.id)
    end)

    it("keeps the python server attached when the doc is updated", function()
        enable_user_python()
        local recipe = setup_project("a")
        local client, bufnr = open_python_doc(recipe)
        yocto.handler(nil, { doc("python", "x = 2", {}, recipe) }, {})
        assert.is_true(vim.lsp.buf_is_attached(bufnr, client.id))
    end)

    it("sends updated python content to the python server", function()
        enable_user_python()
        local recipe = setup_project("a")
        open_python_doc(recipe)
        yocto.handler(nil, { doc("python", "x = 2", {}, recipe) }, {})
        local uri = yocto.get_embedded_uri(recipe, "python")
        assert.is_true((vim.wait(500, function()
            local text
            for _, m in ipairs(messages) do
                local td = m.params and m.params.textDocument
                if td and td.uri == uri then
                    if m.method == "textDocument/didOpen" then
                        text = td.text
                    elseif m.method == "textDocument/didChange" then
                        text = m.params.contentChanges[#m.params.contentChanges].text
                    end
                end
            end
            return text == "x = 2\n"
        end, 10)))
    end)

    it("does not change the user's lsp config", function()
        enable_user_python()
        open_python_doc(setup_project("a"))
        local config = vim.lsp.config.user_python
        assert.is_nil(config.root_dir)
        assert.is_nil(config.settings)
        assert.is_nil(config.cmd_env)
    end)

    it("adds no paths for recipes outside a project", function()
        enable_user_python()
        local client = open_python_doc(vim.uri_from_fname(write("loose/foo_1.0.bb")))
        assert.is_nil(vim.tbl_get(client.settings, "python", "analysis", "extraPaths"))
        assert.is_nil(vim.tbl_get(client.config, "cmd_env", "PYTHONPATH"))
    end)
end)

describe("real python servers find bitbake modules of the project", function()
    -- pyright takes over a second to start; its paths are covered by the
    -- settings tests with a fake server.
    local SERVERS = {
        { name = "zubanls", cmd = { "zuban", "server" } },
    }

    local yocto, root, write, recipe_buf, recipe_uri

    local function proxy_request(method, position)
        local proxy = vim.lsp.get_clients({ bufnr = recipe_buf, name = "yocto_embedded" })[1]
        if not proxy then
            return nil
        end
        local response = proxy:request_sync(
            method,
            { textDocument = { uri = recipe_uri }, position = position },
            500,
            recipe_buf
        )
        return response and response.result
    end

    local function proxy_hover(position)
        return proxy_request("textDocument/hover", position)
    end

    before_each(function()
        yocto = require("yocto")
        yocto.storage_dir = vim.fn.tempname()
        root, write = temp_tree()
        write("sources/poky/bitbake/lib/bb/__init__.py", {
            "def note(msg):",
            '    """yocto test doc"""',
        })
        write("sources/poky/meta/lib/oe/__init__.py")
        local path = write("sources/meta-foo/recipes-foo/foo/foo_1.0.bb", {
            'SUMMARY = "foo"',
            "python do_foo() {",
            '    bb.note("hi")',
            "}",
        })
        recipe_uri = vim.uri_from_fname(path)
        recipe_buf = vim.fn.bufadd(path)
    end)

    after_each(function()
        stop_servers()
        vim.lsp.config.user_python = {}
        remove_storage(yocto.storage_dir)
        vim.api.nvim_buf_delete(recipe_buf, { force = true })
        vim.fn.delete(root, "rf")
    end)

    for _, server in ipairs(SERVERS) do
        it("resolves bb with " .. server.name, function()
            vim.lsp.config("user_python", {
                cmd = server.cmd,
                filetypes = { "python" },
                root_markers = { ".git" },
            })
            vim.lsp.enable("user_python")
            vim.fn.bufload(recipe_buf)

            local contents
            vim.wait(500, function()
                local result = proxy_hover(pos(2, 8))
                contents = result and vim.inspect(result.contents)
                return contents ~= nil and contents:find("yocto test doc", 1, true) ~= nil
            end, 50)
            assert.is_not_nil(contents and contents:find("yocto test doc", 1, true))
        end)

        it("jumps to bb definitions with " .. server.name, function()
            vim.lsp.config("user_python", { cmd = server.cmd, filetypes = { "python" } })
            vim.lsp.enable("user_python")
            vim.fn.bufload(recipe_buf)

            local target
            vim.wait(500, function()
                local result = proxy_request("textDocument/definition", pos(2, 8))
                local location = result and (result[1] or result)
                target = location and (location.uri or location.targetUri)
                return target ~= nil
            end, 50)
            assert.is_not_nil(target and target:find("bitbake/lib/bb/__init__.py", 1, true))
        end)

        it("completes bb members with " .. server.name, function()
            vim.lsp.config("user_python", { cmd = server.cmd, filetypes = { "python" } })
            vim.lsp.enable("user_python")
            vim.fn.bufload(recipe_buf)

            local labels = {}
            vim.wait(500, function()
                local result = proxy_request("textDocument/completion", pos(2, 7))
                for _, item in ipairs(result and (result.items or result) or {}) do
                    labels[item.label] = true
                end
                return labels.note ~= nil
            end, 50)
            assert.is_true(labels.note)
        end)
    end
end)
