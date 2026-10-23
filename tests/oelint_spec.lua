local describe = require("plenary.busted").describe
local it = require("plenary.busted").it
local before_each = require("plenary.busted").before_each
local after_each = require("plenary.busted").after_each

local severity = vim.diagnostic.severity

-- Creates a listed buffer named `name` holding `lines`.
local function make_buf(name, lines)
    local bufnr = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(bufnr, name)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    return bufnr
end

describe("oelint output parsing", function()
    local oelint, bufnr
    local NAME = "/tmp/meta/recipes/foo/foo_1.0.bb"

    before_each(function()
        oelint = require("yocto.oelint")
        bufnr = make_buf(NAME, { 'SUMMARY = "x"', "", '  SRC_URI = "file://a"  ' })
    end)

    after_each(function()
        vim.api.nvim_buf_delete(bufnr, { force = true })
    end)

    it("returns no diagnostics for empty output", function()
        assert.are.same({}, oelint.parse("", bufnr))
    end)

    it("ignores lines that are not findings", function()
        local out = "Loaded rules:\n\toelint.var.order\nParsing " .. NAME .. "\n"
        assert.are.same({}, oelint.parse(out, bufnr))
    end)

    it("turns a finding into a diagnostic on its zero-based line", function()
        local out = NAME .. ":1:error:oelint.var.mandatoryvar.HOMEPAGE:Variable 'HOMEPAGE' should be set\n"
        local d = oelint.parse(out, bufnr)
        assert.are.equal(1, #d)
        assert.are.equal(0, d[1].lnum)
        assert.are.equal(0, d[1].end_lnum)
        assert.are.equal(severity.ERROR, d[1].severity)
        assert.are.equal("Variable 'HOMEPAGE' should be set", d[1].message)
        assert.are.equal("oelint.var.mandatoryvar.HOMEPAGE", d[1].source)
    end)

    it("maps warning and info severities", function()
        local out = NAME .. ":1:warning:a.b:w\n" .. NAME .. ":1:info:a.c:i\n"
        local d = oelint.parse(out, bufnr)
        assert.are.equal(severity.WARN, d[1].severity)
        assert.are.equal(severity.INFO, d[2].severity)
    end)

    it("keeps colons inside the message", function()
        local d = oelint.parse(NAME .. ":1:info:a.b:see: here\n", bufnr)
        assert.are.equal("see: here", d[1].message)
    end)

    it("spans the non-blank text of the line", function()
        local d = oelint.parse(NAME .. ":3:warning:oelint.spaces.linebeginning:x\n", bufnr)
        assert.are.equal(2, d[1].col)
        assert.are.equal(22, d[1].end_col)
    end)

    it("starts at column 0 on an empty line", function()
        local d = oelint.parse(NAME .. ":2:info:a.b:x\n", bufnr)
        assert.are.equal(0, d[1].col)
    end)

    it("skips findings in other files", function()
        local out = "/tmp/meta/classes/other.bbclass:1:error:a.b:x\n"
        assert.are.same({}, oelint.parse(out, bufnr))
    end)

    it("handles CRLF line endings", function()
        local d = oelint.parse(NAME .. ":1:info:a.b:msg\r\n", bufnr)
        assert.are.equal("msg", d[1].message)
    end)
end)

-- Writes an executable stand-in for oelint-adv to dir that records its
-- arguments in dir/args, sleeps `delay` seconds and prints `stderr`.
local function fake_oelint(dir, stderr, delay)
    vim.fn.mkdir(dir, "p")
    local path = dir .. "/oelint-adv"
    vim.fn.writefile({
        "#!/bin/sh",
        'printf "%s\\n" "$@" > "' .. dir .. '/args"',
        "sleep " .. (delay or 0),
        "cat >&2 <<'OUT'",
        stderr or "",
        "OUT",
    }, path)
    vim.fn.setfperm(path, "rwxr-xr-x")
    return path
end

-- Sets the filetype without triggering FileType autocommands, which would
-- start language servers and lint runs of their own.
local function set_filetype(bufnr, filetype)
    vim.api.nvim_buf_call(bufnr, function()
        vim.cmd("noautocmd setlocal filetype=" .. filetype)
    end)
end

local function wait_done(oelint)
    assert.is_true(vim.wait(10000, function()
        return not oelint.running()
    end, 10))
end

describe("oelint run", function()
    local oelint, dir, bufnr, name, original_cmd, original_cachedir

    before_each(function()
        oelint = require("yocto.oelint")
        original_cmd = oelint.cmd
        original_cachedir = oelint.cachedir
        dir = vim.fn.tempname()
        vim.fn.mkdir(dir, "p")
        name = dir .. "/foo_1.0.bb"
        vim.fn.writefile({ 'SUMMARY = "x"' }, name)
        bufnr = vim.fn.bufadd(name)
        vim.fn.bufload(bufnr)
        set_filetype(bufnr, "bitbake")
    end)

    after_each(function()
        oelint.stop()
        oelint.cmd = original_cmd
        oelint.cachedir = original_cachedir
        vim.api.nvim_buf_delete(bufnr, { force = true })
        vim.fn.delete(dir, "rf")
    end)

    it("refuses when oelint-adv is not executable", function()
        oelint.cmd = dir .. "/missing"
        local ok, err = oelint.run(bufnr)
        assert.is_false(ok)
        assert.are.equal(dir .. "/missing not found", err)
    end)

    it("refuses buffers that are not bitbake files", function()
        oelint.cmd = fake_oelint(dir .. "/bin")
        set_filetype(bufnr, "python")
        local ok, err = oelint.run(bufnr)
        assert.is_false(ok)
        assert.are.equal("not a bitbake buffer", err)
    end)

    it("refuses modified buffers", function()
        oelint.cmd = fake_oelint(dir .. "/bin")
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "changed" })
        local ok, err = oelint.run(bufnr)
        assert.is_false(ok)
        assert.are.equal("buffer has unsaved changes", err)
    end)

    it("sets diagnostics from the output", function()
        oelint.cmd = fake_oelint(dir .. "/bin", name .. ":1:error:a.b:broken")
        assert.is_true(oelint.run(bufnr))
        wait_done(oelint)
        local d = vim.diagnostic.get(bufnr, { namespace = oelint.namespace })
        assert.are.equal(1, #d)
        assert.are.equal("broken", d[1].message)
    end)

    it("clears old diagnostics when it starts", function()
        oelint.cmd = fake_oelint(dir .. "/bin", "", 1)
        vim.diagnostic.set(oelint.namespace, bufnr, { { lnum = 0, col = 0, message = "old" } })
        oelint.run(bufnr)
        assert.are.same({}, vim.diagnostic.get(bufnr, { namespace = oelint.namespace }))
    end)

    it("passes the cache options, extra arguments and file name", function()
        oelint.cmd = fake_oelint(dir .. "/bin")
        oelint.run(bufnr, { args = { "--quiet", "--fix" } })
        wait_done(oelint)
        local args = vim.fn.readfile(dir .. "/bin/args")
        assert.are.same({ "--cached", "--cachedir", oelint.cachedir, "--quiet", "--fix", name }, args)
    end)

    it("refuses to start while a run is in progress", function()
        oelint.cmd = fake_oelint(dir .. "/bin", "", 5)
        assert.is_true(oelint.run(bufnr))
        local ok, err = oelint.run(bufnr)
        assert.is_false(ok)
        assert.are.equal("oelint-adv is still running", err)
    end)

    it("restarts a run in progress when forced", function()
        oelint.cmd = fake_oelint(dir .. "/bin", "", 5)
        oelint.run(bufnr)
        oelint.cmd = fake_oelint(dir .. "/bin2", name .. ":1:info:a.b:second")
        assert.is_true(oelint.run(bufnr, { force = true }))
        wait_done(oelint)
        local d = vim.diagnostic.get(bufnr, { namespace = oelint.namespace })
        assert.are.equal(1, #d)
        assert.are.equal("second", d[1].message)
    end)

    it("lints with the real oelint-adv", function()
        if vim.fn.executable("oelint-adv") == 0 then
            return
        end
        oelint.cmd = "oelint-adv"
        oelint.cachedir = dir .. "/cache"
        assert.is_true(oelint.run(bufnr))
        wait_done(oelint)
        local sources = vim.tbl_map(function(d)
            return d.source
        end, vim.diagnostic.get(bufnr, { namespace = oelint.namespace }))
        assert.is_true(vim.tbl_contains(sources, "oelint.var.mandatoryvar.HOMEPAGE"))
    end)
end)

describe("oelint autocommands", function()
    local oelint, dir, bufnr, name, original_cmd

    before_each(function()
        oelint = require("yocto.oelint")
        original_cmd = oelint.cmd
        dir = vim.fn.tempname()
        oelint.cmd = fake_oelint(dir .. "/bin")
        name = dir .. "/foo_1.0.bb"
        vim.fn.writefile({ 'SUMMARY = "x"' }, name)
        bufnr = vim.fn.bufadd(name)
        vim.fn.bufload(bufnr)
        set_filetype(bufnr, "bitbake")
        -- Loading a .bb file detects its filetype, which already starts a run.
        oelint.stop()
    end)

    after_each(function()
        oelint.stop()
        oelint.cmd = original_cmd
        vim.api.nvim_buf_delete(bufnr, { force = true })
        vim.fn.delete(dir, "rf")
    end)

    it("lints bitbake buffers when they are written", function()
        vim.api.nvim_exec_autocmds("BufWritePost", { buffer = bufnr, modeline = false })
        assert.is_true(oelint.running())
    end)

    it("lints buffers when they become bitbake buffers", function()
        vim.api.nvim_exec_autocmds("FileType", { buffer = bufnr, modeline = false })
        assert.is_true(oelint.running())
    end)

    it("restarts a run in progress when the buffer is written again", function()
        oelint.cmd = fake_oelint(dir .. "/bin", "", 5)
        vim.api.nvim_exec_autocmds("BufWritePost", { buffer = bufnr, modeline = false })
        oelint.cmd = fake_oelint(dir .. "/bin2", name .. ":1:info:a.b:second")
        vim.api.nvim_exec_autocmds("BufWritePost", { buffer = bufnr, modeline = false })
        wait_done(oelint)
        local d = vim.diagnostic.get(bufnr, { namespace = oelint.namespace })
        assert.are.equal("second", d[1].message)
    end)

    it("does not lint other buffers when they are written", function()
        set_filetype(bufnr, "python")
        vim.api.nvim_exec_autocmds("BufWritePost", { buffer = bufnr, modeline = false })
        assert.is_false(oelint.running())
    end)
end)
