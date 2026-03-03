#lang racket/base
;; Truthiness predicate tests
;;
;; Tests all three truthiness variants (OValue, Handlebars, JMESPath)
;; with emphasis on the key difference: 0 is falsy in iidy but
;; truthy in Handlebars/JMESPath.

(require redex/reduction-semantics
         rackunit
         "../lang/core.rkt"
         "../semantics/truthiness.rkt")

(provide truthiness-tests)

(define truthiness-tests
  (test-suite
   "Truthiness predicates"

   ;; ── iidy OValue truthiness ────────────────────────────────────

   (test-suite
    "OValue truthiness (truthy)"

    (test-case "null is falsy"
      (check-equal? (term (truthy null)) #f))

    (test-case "true is truthy"
      (check-equal? (term (truthy (bool #t))) #t))

    (test-case "false is falsy"
      (check-equal? (term (truthy (bool #f))) #f))

    (test-case "empty string is falsy"
      (check-equal? (term (truthy (str ""))) #f))

    (test-case "non-empty string is truthy"
      (check-equal? (term (truthy (str "hello"))) #t))

    (test-case "zero is falsy"
      (check-equal? (term (truthy (num 0))) #f))

    (test-case "non-zero number is truthy"
      (check-equal? (term (truthy (num 42))) #t))

    (test-case "negative number is truthy"
      (check-equal? (term (truthy (num -1))) #t))

    (test-case "empty array is falsy"
      (check-equal? (term (truthy (arr ()))) #f))

    (test-case "non-empty array is truthy"
      (check-equal? (term (truthy (arr ((num 1))))) #t))

    (test-case "empty object is falsy"
      (check-equal? (term (truthy (obj ()))) #f))

    (test-case "non-empty object is truthy"
      (check-equal? (term (truthy (obj (("a" (num 1)))))) #t)))

   ;; ── Handlebars truthiness ─────────────────────────────────────

   (test-suite
    "Handlebars truthiness (truthy/hbs)"

    (test-case "null is falsy"
      (check-equal? (term (truthy/hbs null)) #f))

    (test-case "true is truthy"
      (check-equal? (term (truthy/hbs (bool #t))) #t))

    (test-case "false is falsy"
      (check-equal? (term (truthy/hbs (bool #f))) #f))

    (test-case "empty string is falsy"
      (check-equal? (term (truthy/hbs (str ""))) #f))

    (test-case "non-empty string is truthy"
      (check-equal? (term (truthy/hbs (str "hello"))) #t))

    (test-case "ZERO IS TRUTHY (Handlebars spec)"
      (check-equal? (term (truthy/hbs (num 0))) #t))

    (test-case "non-zero number is truthy"
      (check-equal? (term (truthy/hbs (num 42))) #t))

    (test-case "empty array is falsy"
      (check-equal? (term (truthy/hbs (arr ()))) #f))

    (test-case "non-empty array is truthy"
      (check-equal? (term (truthy/hbs (arr ((num 1))))) #t))

    (test-case "empty object is falsy"
      (check-equal? (term (truthy/hbs (obj ()))) #f))

    (test-case "non-empty object is truthy"
      (check-equal? (term (truthy/hbs (obj (("a" (num 1)))))) #t)))

   ;; ── JMESPath truthiness ───────────────────────────────────────

   (test-suite
    "JMESPath truthiness (truthy/jmespath)"

    (test-case "ZERO IS TRUTHY (JMESPath spec)"
      (check-equal? (term (truthy/jmespath (num 0))) #t))

    (test-case "null is falsy"
      (check-equal? (term (truthy/jmespath null)) #f))

    (test-case "empty string is falsy"
      (check-equal? (term (truthy/jmespath (str ""))) #f)))

   ;; ── Cross-variant comparison ──────────────────────────────────

   (test-suite
    "Key truthiness difference: zero"

    (test-case "iidy says 0 is falsy; Handlebars says truthy"
      (check-equal? (term (truthy (num 0))) #f)
      (check-equal? (term (truthy/hbs (num 0))) #t))

    (test-case "iidy says 0 is falsy; JMESPath says truthy"
      (check-equal? (term (truthy (num 0))) #f)
      (check-equal? (term (truthy/jmespath (num 0))) #t)))))
