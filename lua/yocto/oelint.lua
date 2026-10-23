-- Lints bitbake files with oelint-adv and reports the findings as
-- diagnostics.

local M = {}

M.namespace = vim.api.nvim_create_namespace("yocto.oelint")

local SEVERITIES = {
    info = vim.diagnostic.severity.INFO,
    warning = vim.diagnostic.severity.WARN,
    error = vim.diagnostic.severity.ERROR,
}

-- Diagnostics for bufnr from oelint-adv output lines of the form
-- "file:line:severity:rule:message". Findings in other files are skipped.
function M.parse(output, bufnr)
    local name = vim.api.nvim_buf_get_name(bufnr)
    local diagnostics = {}
    for line in output:gmatch("[^\r\n]+") do
        local file, lnum, severity, rule, message = line:match("^([^:]+):(%d+):(%a+):([^:]+):(.+)$")
        if file == name and SEVERITIES[severity] then
            lnum = tonumber(lnum) - 1
            local text = vim.api.nvim_buf_get_lines(bufnr, lnum, lnum + 1, false)[1] or ""
            table.insert(diagnostics, {
                lnum = lnum,
                end_lnum = lnum,
                col = (text:find("%S") or 1) - 1,
                end_col = text:find("%s*$") - 1,
                severity = SEVERITIES[severity],
                message = message,
                source = rule,
            })
        end
    end
    return diagnostics
end

M.cmd = "oelint-adv"
M.cachedir = vim.fs.joinpath(vim.uv.os_tmpdir(), "oelint")

local job -- the oelint-adv process in progress

function M.running()
    return job ~= nil
end

function M.stop()
    if job then
        job:kill("sigterm")
        job = nil
    end
end

-- Lints the file of bufnr and sets its diagnostics once oelint-adv is done.
-- opts.args are extra oelint-adv arguments; opts.force restarts a run in
-- progress. Returns true, or false and the reason it did not start.
function M.run(bufnr, opts)
    opts = opts or {}
    if vim.fn.executable(M.cmd) == 0 then
        return false, M.cmd .. " not found"
    end
    if vim.bo[bufnr].filetype ~= "bitbake" then
        return false, "not a bitbake buffer"
    end
    if vim.bo[bufnr].modified then
        return false, "buffer has unsaved changes"
    end
    if job and not opts.force then
        return false, "oelint-adv is still running, use :Oelint! to restart it"
    end
    M.stop()

    vim.diagnostic.set(M.namespace, bufnr, {})
    local cmd = { M.cmd, "--cached", "--cachedir", M.cachedir }
    vim.list_extend(cmd, opts.args or {})
    table.insert(cmd, vim.api.nvim_buf_get_name(bufnr))

    local this
    this = vim.system(cmd, { text = true }, function(result)
        vim.schedule(function()
            -- A killed or restarted run must not overwrite newer results.
            if job ~= this then
                return
            end
            job = nil
            if vim.api.nvim_buf_is_valid(bufnr) then
                vim.diagnostic.set(M.namespace, bufnr, M.parse(result.stderr or "", bufnr))
            end
        end)
    end)
    job = this
    return true
end

return M
