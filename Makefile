.PHONY: test deps lint fmt fmt-check typecheck check clean

DEPS_DIR := deps

deps: $(DEPS_DIR)/sqlite.lua

$(DEPS_DIR)/sqlite.lua:
	@mkdir -p $(DEPS_DIR)
	git clone --depth 1 https://github.com/kkharji/sqlite.lua $@

test: deps
	vusted --output=utfTerminal --helper test/minimal_init.lua test/spec/

ifdef FILE
test: deps
	vusted --output=utfTerminal --helper test/minimal_init.lua $(FILE)
endif

lint:
	luacheck lua/ test/

fmt:
	stylua lua/ test/

fmt-check:
	stylua --check lua/ test/

typecheck:
	lua-language-server --check lua/ --checklevel=Warning

check: lint fmt-check test

clean:
	rm -rf $(DEPS_DIR)
