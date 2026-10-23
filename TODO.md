
React to the general LSP command that is sent from language-server-bitbake to
get python and bash aware features


---

Essentially re-writing parts of the vscode-bitbake extension client side logic
in a neovim plugin

---

Clean up when a recipe is closed: wipe its hidden embedded buffers, stop
language servers left with no buffers and forget its recorded docs. Today they
live until neovim exits.

---

Fix bash-language-server hover text like vscode-bitbake does
(client/src/language/middlewareHover.ts:69-94): resolve relative .bbclass
paths and correct "defined on line N" to the recipe's line numbers.

---

python functions defined in classes do not work for go to definition
