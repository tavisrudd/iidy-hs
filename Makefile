.PHONY: build test clean run help ci ci-act

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

ci:
	cabal update
	cabal build all --ghc-options="-Wall -Wcompat -Werror"
	cabal test all --test-show-details=direct
	cabal run iidy-hs -- --help
	cabal run iidy-hs -- --version

ci-act:
	nix run nixpkgs#act -- -j build
