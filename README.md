# yocto.nvim

Python and bash language features inside BitBake recipes, like the
[vscode-bitbake](https://github.com/yoctoproject/vscode-bitbake) extension.

## Requirements

- Neovim 0.12+
- `language-server-bitbake`
- a bash and a python language server (e.g. `bash-language-server`,
  `pyright`, `zuban`)

## Usage

Install the plugin. No setup needed.

```lua
vim.pack.add('https://github.com/anakin4747/yocto.nvim')
```

## Config

Your own `vim.lsp.config` servers for `bitbake`, `sh` and `python` are used
when enabled; otherwise `yocto_bitbake`, `yocto_bash` and `yocto_python`
fallbacks are started. So any `python` or `sh` server can be used.

Here is how you could customize things if you wanted to but it is completely
optional as this is the fallback behaviour of the plugin:

```lua
local server_commands = {
    sh = { 'bash-language-server', 'start' },
    bitbake = { 'language-server-bitbake', '--stdio' },
    python = { "pyright-langserver", "--stdio" },
}

for filetype, command in pairs(server_commands) do
    vim.lsp.config(filetype, {
        root_markers = { '.git' },
        filetypes = { filetype },
        cmd = command,
    })
    vim.lsp.enable(filetype)
end
```

## Tests

Run `make` to run the tests in a docker container:

```sh
make
```
