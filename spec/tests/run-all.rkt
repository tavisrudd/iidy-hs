#lang racket/base
;; Master test runner for iidy PLT Redex formal semantics
;;
;; Run:  racket tests/run-all.rkt
;; From: spec/ directory

(require redex/reduction-semantics
         rackunit
         rackunit/text-ui
         "grammar-tests.rkt"
         "truthiness-tests.rkt"
         "env-tests.rkt"
         "merge-tests.rkt"
         "eval-tests.rkt"
         "properties.rkt"
         "handlebars-tests.rkt"
         "jmespath-tests.rkt"
         "bracket-expansion-tests.rkt")

;; Enable redundancy checking: metafunctions and judgment forms will
;; report if any clause is completely shadowed by earlier clauses.
(check-redundancy #t)

(define all-tests
  (test-suite
   "iidy formal semantics"
   grammar-tests
   truthiness-tests
   env-tests
   merge-tests
   eval-tests
   property-tests
   handlebars-tests
   jmespath-tests
   bracket-expansion-tests))

;; Coverage note: Redex's make-coverage/relation-coverage API only
;; supports reduction relations, not judgment forms or metafunctions.
;; Eval rule coverage is verified structurally — eval-tests.rkt has
;; dedicated tests for each named rule (E-Null through E-ToJson),
;; and properties.rkt exercises rules via redex-check generators.
;;
;; Eval rules and their test coverage:
;;   E-Null, E-Bool, E-Num, E-Str, E-Arr, E-Obj  — eval-tests, properties
;;   E-Seq, E-Obj-E                                — eval-tests
;;   E-Var, E-Var-Q                                — eval-tests
;;   E-IfTrue, E-IfFalse                           — eval-tests
;;   E-Let                                         — eval-tests
;;   E-Eq, E-Not                                   — eval-tests, properties
;;   E-Split, E-Join                               — eval-tests
;;   E-Map, E-MapF, E-ConcatMap, E-ConcatMapF      — eval-tests
;;   E-Concat, E-Merge                             — eval-tests, properties
;;   E-MergeMap, E-FromPairs, E-MapListToHash       — eval-tests
;;   E-MapListToHashF, E-MapValues, E-GroupBy       — eval-tests
;;   E-Escape                                      — eval-tests, properties
;;   E-Cfn                                         — eval-tests
;;   E-Tpl                                         — eval-tests
;;   E-ToYaml, E-ToJson                            — eval-tests, properties

(define exit-code
  (run-tests all-tests 'verbose))

(exit (if (zero? exit-code) 0 1))
