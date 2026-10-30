
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
:Bitbake scan runs the scan
```

---

Support neovim as a terminal provider upstream so that you don't need to use
tmux for devshells

---

how to record videos at a compressed rate to above post processing to show
small snippets of features instead of a long demo

---

investigate feasibility of reusing vscode-bitbake source code via
`remote-plugin`

---

Replace all descibe blocks with the function names they test to clarify



----

how can I make them all show their filepath:linenumber in a grey fg and a clear
bg

---

Tests may be no longer than 3s without a test failing catching that.
This makes it so that this test needs to be changed to enforce approval to
increase that 3s limit

