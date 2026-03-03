#lang racket/base
;; Master test runner for iidy PLT Redex formal semantics
;;
;; Run:  racket tests/run-all.rkt
;; From: spec/ directory

(require rackunit
         rackunit/text-ui
         "grammar-tests.rkt"
         "truthiness-tests.rkt"
         "eval-tests.rkt")

(define all-tests
  (test-suite
   "iidy formal semantics"
   grammar-tests
   truthiness-tests
   eval-tests))

(define exit-code
  (run-tests all-tests 'verbose))

(exit (if (zero? exit-code) 0 1))
