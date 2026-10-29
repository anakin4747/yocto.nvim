
Clean up when a recipe is closed: wipe its hidden embedded buffers, stop
language servers left with no buffers and forget its recorded docs. Today they
live until neovim exits.

---

Fix bash-language-server hover text like vscode-bitbake does
(client/src/language/middlewareHover.ts:69-94): resolve relative .bbclass
paths and correct "defined on line N" to the recipe's line numbers.

---

Go to definition of python functions searches inherited classes and the
classes-global of bblayers.conf layers: also search require/include files.

---

python diagnostics don't show up

---

Maybe extending this plugin to support running explicit bitbake commands with:

```vim
:Bitbake
```

---

Support neovim as a terminal provider upstream so that you don't need to use
tmux for devshells

---

how to record videos at a compressed rate to above post processing to show
small snippets of features instead of a long demo

---

These need to be reviewed as poky is no longer the mega repo that it once was,
so this plugin shouldn't be searching for poky.

```
SUCCESS bitbake_python_paths finds poky under sources
SUCCESS bitbake_python_paths finds separate bitbake and openembedded-core under sources
SUCCESS bitbake_python_paths finds poky under layers
SUCCESS bitbake_python_paths finds separate bitbake and openembedded-core under layers
SUCCESS bitbake_python_paths finds bitbake when the project root is poky itself
```
