.PHONY: build test app demo lint

build:
	swift build

test:
	swift run mux-beacon-self-test

app:
	./scripts/build-app.sh

demo:
	swift run mux-beacon demo

lint:
	zsh -n scripts/*.sh
