
.PHONY: cqfd
cqfd:
	@# @./scripts/cqfd init > /dev/null
	@./scripts/cqfd run make tests

.PHONY: test tests
test tests:
	@cog check --from-latest-tag
	@./scripts/run_tests

INSTALL_DIR ?= $(HOME)/.local/share/nvim/site/pack/core/opt/yocto.nvim

.PHONY: install-dev
install-dev:
	rm -rf $(INSTALL_DIR)
	cp -r . $(INSTALL_DIR)
