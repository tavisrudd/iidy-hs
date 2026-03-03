#lang racket/base
;; Tests for JMESPath query evaluation semantics

(require rackunit
         redex/reduction-semantics
         "../lang/core.rkt"
         "../lang/jmespath.rkt"
         "../semantics/jmespath-eval.rkt")
(provide jmespath-tests)


;; ═══════════════════════════════════════════════════════════════════
;; Test data
;; ═══════════════════════════════════════════════════════════════════

;; {"a": 1, "b": {"c": 3}, "items": [{"name": "x", "v": 1}, {"name": "y", "v": 2}]}
(define test-obj
  (term (obj (("a" (num 1))
              ("b" (obj (("c" (num 3)))))
              ("items" (arr ((obj (("name" (str "x")) ("v" (num 1))))
                             (obj (("name" (str "y")) ("v" (num 2)))))))))))

;; [1, 2, 3, 4, 5]
(define test-arr
  (term (arr ((num 1) (num 2) (num 3) (num 4) (num 5)))))


;; ═══════════════════════════════════════════════════════════════════
;; Grammar tests
;; ═══════════════════════════════════════════════════════════════════

(define grammar-tests
  (test-suite
   "JMESPath grammar"

   (test-case "field"
     (check-not-false (redex-match? Iidy-JMESPath jx (term (jfield "a")))))

   (test-case "index"
     (check-not-false (redex-match? Iidy-JMESPath jx (term (jindex 0)))))

   (test-case "negative index"
     (check-not-false (redex-match? Iidy-JMESPath jx (term (jindex -1)))))

   (test-case "sub-expression"
     (check-not-false (redex-match? Iidy-JMESPath jx (term (jsub (jfield "a") (jfield "b"))))))

   (test-case "wildcard"
     (check-not-false (redex-match? Iidy-JMESPath jx (term jwildcard))))

   (test-case "projection"
     (check-not-false (redex-match? Iidy-JMESPath jx (term (jproj (jfield "items") (jfield "name"))))))

   (test-case "filter"
     (check-not-false (redex-match? Iidy-JMESPath jx
                        (term (jfilter (jcmp > (jfield "v") (jlit (num 1))) jidentity)))))

   (test-case "multi-select hash"
     (check-not-false (redex-match? Iidy-JMESPath jx
                        (term (jmulti-hash (("x" (jfield "a")) ("y" (jfield "b"))))))))

   (test-case "multi-select list"
     (check-not-false (redex-match? Iidy-JMESPath jx
                        (term (jmulti-list ((jfield "a") (jfield "b")))))))

   (test-case "pipe"
     (check-not-false (redex-match? Iidy-JMESPath jx
                        (term (jpipe (jfield "items") (jindex 0))))))

   (test-case "comparison"
     (check-not-false (redex-match? Iidy-JMESPath jx
                        (term (jcmp == (jfield "a") (jlit (num 1)))))))))


;; ═══════════════════════════════════════════════════════════════════
;; Field access tests
;; ═══════════════════════════════════════════════════════════════════

(define field-tests
  (test-suite
   "jeval: field access"

   (test-case "top-level field"
     (check-equal? (term (jeval (jfield "a") ,test-obj)) (term (num 1))))

   (test-case "missing field returns null"
     (check-equal? (term (jeval (jfield "missing") ,test-obj)) (term null)))

   (test-case "field on non-object returns null"
     (check-equal? (term (jeval (jfield "x") (num 42))) (term null)))

   (test-case "nested field via sub-expression"
     (check-equal? (term (jeval (jsub (jfield "b") (jfield "c")) ,test-obj))
                   (term (num 3))))))


;; ═══════════════════════════════════════════════════════════════════
;; Index tests
;; ═══════════════════════════════════════════════════════════════════

(define index-tests
  (test-suite
   "jeval: array index"

   (test-case "positive index"
     (check-equal? (term (jeval (jindex 0) ,test-arr)) (term (num 1))))

   (test-case "last element"
     (check-equal? (term (jeval (jindex 4) ,test-arr)) (term (num 5))))

   (test-case "negative index (-1 = last)"
     (check-equal? (term (jeval (jindex -1) ,test-arr)) (term (num 5))))

   (test-case "negative index (-2 = second to last)"
     (check-equal? (term (jeval (jindex -2) ,test-arr)) (term (num 4))))

   (test-case "out of bounds returns null"
     (check-equal? (term (jeval (jindex 10) ,test-arr)) (term null)))

   (test-case "index on non-array returns null"
     (check-equal? (term (jeval (jindex 0) (str "hello"))) (term null)))))


;; ═══════════════════════════════════════════════════════════════════
;; Identity and literal tests
;; ═══════════════════════════════════════════════════════════════════

(define identity-literal-tests
  (test-suite
   "jeval: identity and literal"

   (test-case "identity returns input"
     (check-equal? (term (jeval jidentity ,test-obj)) test-obj))

   (test-case "literal string"
     (check-equal? (term (jeval (jlit (str "hello")) ,test-obj)) (term (str "hello"))))

   (test-case "literal number"
     (check-equal? (term (jeval (jlit (num 99)) ,test-obj)) (term (num 99))))

   (test-case "literal null"
     (check-equal? (term (jeval (jlit null) ,test-obj)) (term null)))))


;; ═══════════════════════════════════════════════════════════════════
;; Wildcard tests
;; ═══════════════════════════════════════════════════════════════════

(define wildcard-tests
  (test-suite
   "jeval: wildcard"

   (test-case "wildcard on object → array of values"
     (check-equal? (term (jeval jwildcard (obj (("x" (num 1)) ("y" (num 2))))))
                   (term (arr ((num 1) (num 2))))))

   (test-case "wildcard on array → pass through"
     (check-equal? (term (jeval jwildcard ,test-arr)) test-arr))

   (test-case "wildcard on scalar → null"
     (check-equal? (term (jeval jwildcard (num 42))) (term null)))))


;; ═══════════════════════════════════════════════════════════════════
;; Projection tests
;; ═══════════════════════════════════════════════════════════════════

(define projection-tests
  (test-suite
   "jeval: projection"

   ;; items[*].name → ["x", "y"]
   (test-case "project field from array of objects"
     (check-equal?
      (term (jeval (jproj (jfield "items") (jfield "name")) ,test-obj))
      (term (arr ((str "x") (str "y"))))))

   ;; items[*].missing → [] (nulls filtered)
   (test-case "projection filters nulls"
     (check-equal?
      (term (jeval (jproj (jfield "items") (jfield "missing")) ,test-obj))
      (term (arr ()))))

   ;; [*].v on array → [1, 2]
   (test-case "wildcard projection"
     (check-equal?
      (term (jeval (jproj jwildcard (jfield "v"))
                   (arr ((obj (("v" (num 1)))) (obj (("v" (num 2))))))))
      (term (arr ((num 1) (num 2))))))

   (test-case "projection on non-array → null"
     (check-equal?
      (term (jeval (jproj (jfield "a") (jfield "x")) ,test-obj))
      (term null)))))


;; ═══════════════════════════════════════════════════════════════════
;; Flatten tests
;; ═══════════════════════════════════════════════════════════════════

(define flatten-tests
  (test-suite
   "jeval: flatten"

   (test-case "flatten nested arrays"
     (check-equal?
      (term (jeval (jflatten jidentity)
                   (arr ((arr ((num 1) (num 2))) (arr ((num 3))) (num 4)))))
      (term (arr ((num 1) (num 2) (num 3) (num 4))))))

   (test-case "flatten flat array (no change)"
     (check-equal?
      (term (jeval (jflatten jidentity) ,test-arr))
      test-arr))

   (test-case "flatten on non-array → null"
     (check-equal?
      (term (jeval (jflatten jidentity) (num 42)))
      (term null)))))


;; ═══════════════════════════════════════════════════════════════════
;; Filter tests
;; ═══════════════════════════════════════════════════════════════════

(define filter-tests
  (test-suite
   "jeval: filter"

   ;; items[?v > 1] → [{name: "y", v: 2}]
   (test-case "filter by comparison"
     (check-equal?
      (term (jeval (jfilter (jcmp > (jfield "v") (jlit (num 1)))
                            jidentity)
                   (arr ((obj (("name" (str "x")) ("v" (num 1))))
                         (obj (("name" (str "y")) ("v" (num 2))))))))
      (term (arr ((obj (("name" (str "y")) ("v" (num 2)))))))))

   ;; [?name == "x"]
   (test-case "filter by equality"
     (check-equal?
      (term (jeval (jfilter (jcmp == (jfield "name") (jlit (str "x")))
                            jidentity)
                   (arr ((obj (("name" (str "x")))) (obj (("name" (str "y"))))))))
      (term (arr ((obj (("name" (str "x")))))))))

   (test-case "filter with projection"
     (check-equal?
      (term (jeval (jfilter (jcmp > (jfield "v") (jlit (num 0)))
                            (jfield "name"))
                   (arr ((obj (("name" (str "a")) ("v" (num 1))))
                         (obj (("name" (str "b")) ("v" (num 0))))))))
      (term (arr ((str "a"))))))

   (test-case "filter on non-array → null"
     (check-equal?
      (term (jeval (jfilter (jcmp == jidentity (jlit (num 1))) jidentity) (num 5)))
      (term null)))))


;; ═══════════════════════════════════════════════════════════════════
;; Multi-select tests
;; ═══════════════════════════════════════════════════════════════════

(define multi-select-tests
  (test-suite
   "jeval: multi-select"

   (test-case "multi-select hash"
     (check-equal?
      (term (jeval (jmulti-hash (("x" (jfield "a")) ("y" (jsub (jfield "b") (jfield "c")))))
                   ,test-obj))
      (term (obj (("x" (num 1)) ("y" (num 3)))))))

   (test-case "multi-select list"
     (check-equal?
      (term (jeval (jmulti-list ((jfield "a") (jsub (jfield "b") (jfield "c"))))
                   ,test-obj))
      (term (arr ((num 1) (num 3))))))))


;; ═══════════════════════════════════════════════════════════════════
;; Pipe tests
;; ═══════════════════════════════════════════════════════════════════

(define pipe-tests
  (test-suite
   "jeval: pipe"

   ;; items | [0] → first item
   (test-case "pipe field to index"
     (check-equal?
      (term (jeval (jpipe (jfield "items") (jindex 0)) ,test-obj))
      (term (obj (("name" (str "x")) ("v" (num 1)))))))

   ;; items | [0] | name → "x"
   (test-case "chained pipes"
     (check-equal?
      (term (jeval (jpipe (jpipe (jfield "items") (jindex 0)) (jfield "name")) ,test-obj))
      (term (str "x"))))))


;; ═══════════════════════════════════════════════════════════════════
;; Comparison tests
;; ═══════════════════════════════════════════════════════════════════

(define comparison-tests
  (test-suite
   "jeval: comparisons"

   (test-case "== true"
     (check-equal? (term (jeval (jcmp == (jfield "a") (jlit (num 1))) ,test-obj))
                   (term (bool #t))))

   (test-case "== false"
     (check-equal? (term (jeval (jcmp == (jfield "a") (jlit (num 2))) ,test-obj))
                   (term (bool #f))))

   (test-case "!= true"
     (check-equal? (term (jeval (jcmp != (jfield "a") (jlit (num 2))) ,test-obj))
                   (term (bool #t))))

   (test-case "< numbers"
     (check-equal? (term (jeval (jcmp < (jlit (num 1)) (jlit (num 2))) ,test-obj))
                   (term (bool #t))))

   (test-case "<= equal"
     (check-equal? (term (jeval (jcmp <= (jlit (num 3)) (jlit (num 3))) ,test-obj))
                   (term (bool #t))))

   (test-case "> numbers"
     (check-equal? (term (jeval (jcmp > (jlit (num 5)) (jlit (num 3))) ,test-obj))
                   (term (bool #t))))

   (test-case ">= false"
     (check-equal? (term (jeval (jcmp >= (jlit (num 1)) (jlit (num 5))) ,test-obj))
                   (term (bool #f))))

   (test-case "ordering on non-numbers → false"
     (check-equal? (term (jeval (jcmp < (jlit (str "a")) (jlit (str "b"))) ,test-obj))
                   (term (bool #f))))

   (test-case "== structural (objects)"
     (check-equal?
      (term (jeval (jcmp == (jfield "b") (jlit (obj (("c" (num 3)))))) ,test-obj))
      (term (bool #t))))))


;; ═══════════════════════════════════════════════════════════════════
;; Negation tests
;; ═══════════════════════════════════════════════════════════════════

(define negation-tests
  (test-suite
   "jeval: negation"

   (test-case "not truthy → false"
     (check-equal? (term (jeval (jnot (jfield "a")) ,test-obj))
                   (term (bool #f))))

   (test-case "not null → true"
     (check-equal? (term (jeval (jnot (jfield "missing")) ,test-obj))
                   (term (bool #t))))

   (test-case "not false → true"
     (check-equal? (term (jeval (jnot (jlit (bool #f))) ,test-obj))
                   (term (bool #t))))))


;; ═══════════════════════════════════════════════════════════════════
;; Master test suite
;; ═══════════════════════════════════════════════════════════════════

(define jmespath-tests
  (test-suite
   "JMESPath sub-language"
   grammar-tests
   field-tests
   index-tests
   identity-literal-tests
   wildcard-tests
   projection-tests
   flatten-tests
   filter-tests
   multi-select-tests
   pipe-tests
   comparison-tests
   negation-tests))
