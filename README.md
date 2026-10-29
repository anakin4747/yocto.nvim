# yocto.nvim

The [vscode-bitbake](https://github.com/yoctoproject/vscode-bitbake) repo
provides the Yocto Project's official Bitbake language server,
`language-server-bitbake`. Some of the language server features are only
available when using the language server with the extension.

This plugin provides some of the client side logic that is only available in
that extension, by communicating with `language-server-bitbake` and
coordinating with Bash and Python language servers.

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

## Documentation

Configuration and features are documented in the help file:

```vim
:h yocto
```

or read [doc/yocto.txt](doc/yocto.txt).

## Tests

Only run tests through `make` so that they are ran through docker with plenary
patched in the rootfs:

```sh
make
```

Tests must remain fast so that the iteration cycle is as short as possible.

New tests shall not increase the time to run tests by more than 0.2 seconds.
This is the current time accepted time on my laptop:
```
time make

real    0m0.958s
user    0m0.732s
sys     0m0.126s
```

## Demo

https://github.com/user-attachments/assets/39d1ecaa-a6d1-4746-8a98-2b58d50e402a
