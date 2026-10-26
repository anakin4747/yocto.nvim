vim.opt.swapfile = false
-- Test files are temporary; do not wait for them to reach the disk.
vim.opt.fsync = false
-- Detect filetypes but load no syntax, indent or ftplugin files for them:
-- embedded buffers get a filetype in nearly every test.
vim.cmd('syntax off')
vim.cmd('filetype on')
vim.cmd('filetype plugin indent off')
vim.opt.runtimepath:append('.')

local plenary_dirs = {
    vim.env.PLENARY_DIR,
    '/usr/local/share/nvim/site/pack/plenary/start/plenary.nvim',
}
for _, d in ipairs(plenary_dirs) do
    if d and vim.fn.isdirectory(d) == 1 then
        vim.opt.runtimepath:append(d)
        break
    end
end

if not pcall(require, 'plenary') then
    io.stderr:write('plenary.nvim not found on runtimepath\n')
    vim.cmd('cquit 1')
end

vim.cmd('runtime plugin/plenary.vim')
vim.cmd('runtime plugin/yocto.lua')

-- Send buffer changes to servers at once instead of after 150ms.
vim.lsp.config('*', { flags = { debounce_text_changes = 0 } })

-- Tests use fake servers; real ones are slow to start. Recording fixtures
-- still needs them, through real_rpc_start. Abort the run: errors raised
-- here are swallowed by vim.lsp.start callers.
_G.real_rpc_start = vim.lsp.rpc.start
vim.lsp.rpc.start = function(cmd)
    io.stderr:write('tests must not start real language servers: ' .. table.concat(cmd, ' ') .. '\n')
    vim.cmd('cquit 1')
end

-- Buffers becoming bitbake buffers start oelint-adv, which is slow and may
-- be installed. Tests that need it fake vim.system and set oelint.cmd.
require('yocto.oelint').cmd = 'oelint-adv-disabled-in-tests'
local system = vim.system
vim.system = function(cmd, ...)
    if cmd[1] == 'oelint-adv' then
        io.stderr:write('tests must not run oelint-adv: ' .. table.concat(cmd, ' ') .. '\n')
        vim.cmd('cquit 1')
    end
    return system(cmd, ...)
end
