.PHONY: build test clean run help

build:
	cabal build

test:
	cabal test

run:
	cabal run iidy-hs -- $(ARGS)

clean:
	cabal clean

help:
	cabal run iidy-hs -- --help

loc:
	@find src app -name '*.hs' | xargs wc -l | tail -1

modules:
	@find src -name '*.hs' | wc -l
