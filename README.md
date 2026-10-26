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

## Config

Your own `vim.lsp.config` server configs for `bitbake`, `sh` and `python` are
used when enabled; otherwise `yocto_bitbake`, `yocto_bash` and `yocto_python`
fallbacks are started. So any `python` or `sh` server can be used.

### Global Config

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

### Project Config

This plugin forwards `bitbake.*` settings in `.vscode/settings.json` to
`language-server-bitbake` and supports finding `bitbake` from
`bitbake.pathToBitbakeFolder`. So project specific config files for
`vscode-bitbake` should also work with this plugin.

Note this plugin currently never runs `bitbake` so it doesn't need the settings
for specifying the environment to run `bitbake` in.

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

## Features

Most features are directly provided by `language-server-bitbake` but this
plugin communicates with it to also support the embedded languages of Bash and
Python in Bitbake files in a similar fashion to `vscode-bitbake`.

Note that many of the features provided by Vim are possible thanks to the
`bitbake.vim` files in your Vim runtime:

```vim
:filter /bitbake.vim/ scriptnames
```

and setting your `'path'` to support recursively searching for files with `gf`
or `gF`:

```vim
:set path+=**
```

### Completion

Partially, thanks to `language-server-bitbake` but not context aware as this
plugin will not run `bitbake` to gather build info.

### Go to definition

| Type | Note |
| --- | --- |
| inherit, include, require | Provided by Vim's `gf` and `gF` with `set path=.,,**` |
| `file://` | Provided by Vim's `v_gf` and `v_gF` with `set path=.,,**` |
| Recipes | Partially provided by Vim's `gf` and `gF` with `set path=.,,**` but only for `bb` files without a version in the path (e.g. recipe.bb and not recipe_%.bb) |
| Python defined in Python files | This plugin to `language-server-bitbake` to your python language server |
| Python defined in Bitbake files | This plugin to `language-server-bitbake` |
| Bash | This plugin to `language-server-bitbake` to your shell language server |

### Hover

For all Yocto and Bitbake variables and keywords provided by
`language-server-bitbake`.

This plugin does not provide the current value of the variables on hover since
this plugin will not run `bitbake` to gather build info.

Hover for Python and Bash functions are provided.

### Linting

This plugin provides linting via
[oelint-adv](https://github.com/priv-kweihmann/oelint-adv). This used to be
provided by another plugin called
[oelint-adv.nvim](https://github.com/anakin4747/oelint-adv.nvim) but it has
been merged into this one.

If you use
[bash-language-server](https://github.com/bash-lsp/bash-language-server) and
have [shellcheck](https://github.com/koalaman/shellcheck) installed then you
will also get `shellcheck` diagnostics in shell based task definitions.

Currently no Python linters have been tested yet.

