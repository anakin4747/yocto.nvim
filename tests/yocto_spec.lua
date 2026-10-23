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
