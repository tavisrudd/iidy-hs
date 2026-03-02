.PHONY: build build-strict test clean run help ci ci-act check-unused-deps

build:
	cabal build

build-strict:
	cabal build all --enable-tests --ghc-options="-Wall -Wcompat -Werror"

test:
	cabal test all --test-show-details=direct

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

check-unused-deps:
	scripts/check-unused-deps.sh

ci:
	$(MAKE) build-strict
	$(MAKE) test
	$(MAKE) check-unused-deps
	cabal run iidy-hs -- --help
	cabal run iidy-hs -- --version

ci-act:
	nix run nixpkgs#act -- -j build
