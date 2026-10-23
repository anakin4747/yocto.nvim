vim.opt.swapfile = false
vim.opt.runtimepath:append('.')
vim.cmd('runtime plugin/plenary.lua')
vim.cmd('runtime plugin/@NAME@.lua')

vim.g.i_am_in_a_test = true
