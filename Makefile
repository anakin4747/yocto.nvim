
.PHONY: cqfd
cqfd:
	@./scripts/cqfd init > /dev/null
	@./scripts/cqfd run make tests

.PHONY: test tests
test tests:
	@cog check --from-latest-tag
	@-./scripts/run_tests
	@./scripts/print_cloc

# Copy the runtime files over the vim.pack checkout for local testing.
INSTALL_DIR ?= $(HOME)/.local/share/nvim/site/pack/core/opt/yocto.nvim

.PHONY: install-dev
install-dev:
	@mkdir -p $(INSTALL_DIR)
	@rsync -a --delete lua plugin $(INSTALL_DIR)/
	@printf 'installed lua/ and plugin/ to %s\n' "$(INSTALL_DIR)"
