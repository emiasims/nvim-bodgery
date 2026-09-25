FILTER ?= .*

NVIM_TEST_VERSION ?= v0.12.5

.DEFAULT_GOAL := test

nvim-test:
	git clone https://github.com/lewis6991/nvim-test
	nvim-test/bin/nvim-test --init

.PHONY: test
test: nvim-test
	NVIM_TEST_VERSION=$(NVIM_TEST_VERSION) \
	nvim-test/bin/nvim-test test \
		--lpath="$(CURDIR)/lua/?.lua;$(CURDIR)/lua/?/init.lua;$(CURDIR)/?.lua" \
		--verbose \
		--filter="$(FILTER)"

	-@stty sane

.PHONY: clean
clean:
	rm -rf nvim-test
