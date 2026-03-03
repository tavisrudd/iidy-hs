#lang racket/base
;; Tests for bracket expansion semantics

(require rackunit
         redex/reduction-semantics
         "../lang/core.rkt"
         "../semantics/bracket-expansion.rkt")
(provide bracket-expansion-tests)


(define test-env
  (term (("env" (str "production"))
         ("region" (str "us-west-2"))
         ("idx" (num 0))
         ("flag" (bool #t)))))


;; ═══════════════════════════════════════════════════════════════════
;; Grammar tests
;; ═══════════════════════════════════════════════════════════════════

(define grammar-tests
  (test-suite
   "BracketExpansion grammar"

   (test-case "literal segment"
     (check-not-false
      (redex-match? Iidy-BracketExpansion bsegment (term "config"))))

   (test-case "bracket-ref segment"
     (check-not-false
      (redex-match? Iidy-BracketExpansion bsegment (term (bracket-ref "env")))))

   (test-case "mixed path"
     (check-not-false
      (redex-match? Iidy-BracketExpansion bpath
                    (term ("config" (bracket-ref "env") "host")))))))


;; ═══════════════════════════════════════════════════════════════════
;; Expansion tests
;; ═══════════════════════════════════════════════════════════════════

(define expansion-tests
  (test-suite
   "expand-path"

   (test-case "no bracket refs — pass through"
     (check-equal?
      (term (expand-path ("config" "db" "host") ,test-env))
      (term ("config" "db" "host"))))

   (test-case "single bracket ref"
     ;; config[env].host → config.production.host
     (check-equal?
      (term (expand-path ("config" (bracket-ref "env") "host") ,test-env))
      (term ("config" "production" "host"))))

   (test-case "multiple bracket refs"
     ;; [env].[region] → production.us-west-2
     (check-equal?
      (term (expand-path ((bracket-ref "env") (bracket-ref "region")) ,test-env))
      (term ("production" "us-west-2"))))

   (test-case "bracket ref to number"
     ;; items[idx] → items.0
     (check-equal?
      (term (expand-path ("items" (bracket-ref "idx")) ,test-env))
      (term ("items" "0"))))

   (test-case "bracket ref to bool"
     (check-equal?
      (term (expand-path ((bracket-ref "flag")) ,test-env))
      (term ("true"))))

   (test-case "bracket ref to missing var → null"
     (check-equal?
      (term (expand-path ((bracket-ref "missing")) ,test-env))
      (term ("null"))))

   (test-case "empty path"
     (check-equal?
      (term (expand-path () ,test-env))
      (term ())))))


;; ═══════════════════════════════════════════════════════════════════
;; Master test suite
;; ═══════════════════════════════════════════════════════════════════

(define bracket-expansion-tests
  (test-suite
   "Bracket expansion"
   grammar-tests
   expansion-tests))
