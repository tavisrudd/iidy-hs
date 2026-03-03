#lang racket/base
;; Unit tests for environment metafunctions
;;
;; Tests: lookup, extend, extend-many, resolve-path,
;;        traverse-path, obj-lookup, arr-index, env-keys

(require redex/reduction-semantics
         rackunit
         "../lang/core.rkt"
         "../semantics/env.rkt")

(provide env-tests)

(define env-tests
  (test-suite
   "Environment metafunctions"

   ;; ── lookup ──────────────────────────────────────────────────────

   (test-suite
    "lookup"

    (test-case "empty environment returns unbound"
      (check-equal? (term (lookup "x" ()))
                    (term unbound)))

    (test-case "finds single binding"
      (check-equal? (term (lookup "x" (("x" (num 42)))))
                    (term (num 42))))

    (test-case "finds binding among others"
      (check-equal? (term (lookup "b" (("a" (num 1)) ("b" (num 2)) ("c" (num 3)))))
                    (term (num 2))))

    (test-case "rightmost wins on shadowed binding"
      (check-equal? (term (lookup "x" (("x" (num 1)) ("x" (num 2)))))
                    (term (num 2))))

    (test-case "triple shadow uses last"
      (check-equal? (term (lookup "x" (("x" (num 1)) ("x" (num 2)) ("x" (num 3)))))
                    (term (num 3))))

    (test-case "missing key returns unbound"
      (check-equal? (term (lookup "z" (("a" (num 1)) ("b" (num 2)))))
                    (term unbound))))

   ;; ── extend ──────────────────────────────────────────────────────

   (test-suite
    "extend"

    (test-case "extend empty environment"
      (check-equal? (term (extend "x" (num 42) ()))
                    (term (("x" (num 42))))))

    (test-case "extend appends to right"
      (check-equal? (term (extend "y" (num 2) (("x" (num 1)))))
                    (term (("x" (num 1)) ("y" (num 2))))))

    (test-case "extend with existing key creates shadow"
      (check-equal? (term (extend "x" (num 99) (("x" (num 1)))))
                    (term (("x" (num 1)) ("x" (num 99)))))))

   ;; ── extend-many ────────────────────────────────────────────────

   (test-suite
    "extend-many"

    (test-case "extend-many with empty bindings"
      (check-equal? (term (extend-many () (("x" (num 1)))))
                    (term (("x" (num 1))))))

    (test-case "extend-many adds multiple bindings in order"
      (check-equal? (term (extend-many (("a" (num 1)) ("b" (num 2))) ()))
                    (term (("a" (num 1)) ("b" (num 2))))))

    (test-case "extend-many into existing environment"
      (check-equal? (term (extend-many (("y" (num 2))) (("x" (num 1)))))
                    (term (("x" (num 1)) ("y" (num 2)))))))

   ;; ── resolve-path ───────────────────────────────────────────────

   (test-suite
    "resolve-path"

    (test-case "empty path returns unbound"
      (check-equal? (term (resolve-path () (("x" (num 1)))))
                    (term unbound)))

    (test-case "single-segment path does direct lookup"
      (check-equal? (term (resolve-path ("x") (("x" (num 42)))))
                    (term (num 42))))

    (test-case "two-segment path traverses into object"
      (check-equal? (term (resolve-path ("cfg" "region")
                                        (("cfg" (obj (("region" (str "us-east-1"))))))))
                    (term (str "us-east-1"))))

    (test-case "three-segment deep path"
      (check-equal? (term (resolve-path ("a" "b" "c")
                                        (("a" (obj (("b" (obj (("c" (num 99)))))))))))
                    (term (num 99))))

    (test-case "path into array by index"
      (check-equal? (term (resolve-path ("items" "1")
                                        (("items" (arr ((str "zero") (str "one")))))))
                    (term (str "one"))))

    (test-case "missing root returns unbound"
      (check-equal? (term (resolve-path ("missing") (("x" (num 1)))))
                    (term unbound)))

    (test-case "missing nested key returns unbound"
      (check-equal? (term (resolve-path ("cfg" "missing")
                                        (("cfg" (obj (("region" (str "us-east-1"))))))))
                    (term unbound))))

   ;; ── traverse-path ──────────────────────────────────────────────

   (test-suite
    "traverse-path"

    (test-case "empty path returns value unchanged"
      (check-equal? (term (traverse-path () (num 42)))
                    (term (num 42))))

    (test-case "traverse into unbound returns unbound"
      (check-equal? (term (traverse-path ("x") unbound))
                    (term unbound)))

    (test-case "traverse into object field"
      (check-equal? (term (traverse-path ("name") (obj (("name" (str "Alice"))))))
                    (term (str "Alice"))))

    (test-case "traverse into nested objects"
      (check-equal? (term (traverse-path ("b" "c") (obj (("b" (obj (("c" (num 7)))))))))
                    (term (num 7))))

    (test-case "traverse into array by index"
      (check-equal? (term (traverse-path ("0") (arr ((str "first") (str "second")))))
                    (term (str "first"))))

    (test-case "traverse into non-traversable returns unbound"
      (check-equal? (term (traverse-path ("x") (num 42)))
                    (term unbound)))

    (test-case "traverse missing object field returns unbound"
      (check-equal? (term (traverse-path ("missing") (obj (("a" (num 1))))))
                    (term unbound))))

   ;; ── obj-lookup ─────────────────────────────────────────────────

   (test-suite
    "obj-lookup"

    (test-case "empty object returns unbound"
      (check-equal? (term (obj-lookup "x" ()))
                    (term unbound)))

    (test-case "finds key in object"
      (check-equal? (term (obj-lookup "a" (("a" (num 1)) ("b" (num 2)))))
                    (term (num 1))))

    (test-case "first match wins (unlike env lookup)"
      (check-equal? (term (obj-lookup "a" (("a" (num 1)) ("a" (num 2)))))
                    (term (num 1))))

    (test-case "missing key returns unbound"
      (check-equal? (term (obj-lookup "z" (("a" (num 1)))))
                    (term unbound))))

   ;; ── arr-index ──────────────────────────────────────────────────

   (test-suite
    "arr-index"

    (test-case "valid index 0"
      (check-equal? (term (arr-index "0" ((str "a") (str "b") (str "c"))))
                    (term (str "a"))))

    (test-case "valid index 2"
      (check-equal? (term (arr-index "2" ((str "a") (str "b") (str "c"))))
                    (term (str "c"))))

    (test-case "out of bounds returns unbound"
      (check-equal? (term (arr-index "5" ((str "a") (str "b"))))
                    (term unbound)))

    (test-case "negative index returns unbound"
      (check-equal? (term (arr-index "-1" ((str "a") (str "b"))))
                    (term unbound)))

    (test-case "non-numeric string returns unbound"
      (check-equal? (term (arr-index "abc" ((str "a") (str "b"))))
                    (term unbound)))

    (test-case "empty array returns unbound"
      (check-equal? (term (arr-index "0" ()))
                    (term unbound))))

   ;; ── env-keys ───────────────────────────────────────────────────

   (test-suite
    "env-keys"

    (test-case "empty environment has no keys"
      (check-equal? (term (env-keys ()))
                    (term ())))

    (test-case "single binding"
      (check-equal? (term (env-keys (("x" (num 1)))))
                    (term ("x"))))

    (test-case "multiple bindings"
      (check-equal? (length (term (env-keys (("a" (num 1)) ("b" (num 2)) ("c" (num 3))))))
                    3))

    (test-case "duplicates removed"
      (check-equal? (length (term (env-keys (("x" (num 1)) ("y" (num 2)) ("x" (num 3))))))
                    2)))))
