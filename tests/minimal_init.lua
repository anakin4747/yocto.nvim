vim.opt.swapfile = false
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

-- Tests use fake servers; real ones are slow to start. Recording fixtures
-- still needs them, through real_rpc_start. Abort the run: errors raised
-- here are swallowed by vim.lsp.start callers.
_G.real_rpc_start = vim.lsp.rpc.start
vim.lsp.rpc.start = function(cmd)
    io.stderr:write('tests must not start real language servers: ' .. table.concat(cmd, ' ') .. '\n')
    vim.cmd('cquit 1')
end

vim.g.i_am_in_a_test = true
