#lang racket/base
;; Grammar well-formedness tests
;;
;; Verify that the grammar accepts valid terms and rejects invalid ones.

(require redex/reduction-semantics
         rackunit
         "../lang/core.rkt"
         "../lang/preprocessing.rkt")

(provide grammar-tests)

(define grammar-tests
  (test-suite
   "Grammar well-formedness"

   ;; ── Core values ────────────────────────────────────────────────

   (test-suite
    "Core values"

    (test-case "null is a value"
      (check-not-false (redex-match? Iidy-Core v (term null))))

    (test-case "booleans are values"
      (check-not-false (redex-match? Iidy-Core v (term (bool #t))))
      (check-not-false (redex-match? Iidy-Core v (term (bool #f)))))

    (test-case "numbers are values"
      (check-not-false (redex-match? Iidy-Core v (term (num 42))))
      (check-not-false (redex-match? Iidy-Core v (term (num 0))))
      (check-not-false (redex-match? Iidy-Core v (term (num -3.14))))
      (check-not-false (redex-match? Iidy-Core v (term (num 1.5e10)))))

    (test-case "strings are values"
      (check-not-false (redex-match? Iidy-Core v (term (str ""))))
      (check-not-false (redex-match? Iidy-Core v (term (str "hello")))))

    (test-case "arrays are values"
      (check-not-false (redex-match? Iidy-Core v (term (arr ()))))
      (check-not-false (redex-match? Iidy-Core v (term (arr ((num 1) (num 2)))))))

    (test-case "objects are values"
      (check-not-false (redex-match? Iidy-Core v (term (obj ()))))
      (check-not-false (redex-match? Iidy-Core v
                         (term (obj (("a" (num 1)) ("b" (str "two"))))))))

    (test-case "nested values"
      (check-not-false (redex-match? Iidy-Core v
                         (term (obj (("items" (arr ((num 1) (num 2))))
                                     ("meta" (obj (("count" (num 2))))))))))

   )  ; end Core values

   ;; ── Environments ──────────────────────────────────────────────

   (test-suite
    "Environments"

    (test-case "empty environment"
      (check-not-false (redex-match? Iidy-Core σ (term ()))))

    (test-case "single binding"
      (check-not-false (redex-match? Iidy-Core σ
                         (term (("x" (num 42)))))))

    (test-case "multiple bindings"
      (check-not-false (redex-match? Iidy-Core σ
                         (term (("x" (num 1)) ("y" (str "hello"))))))))

   ;; ── Preprocessing expressions ─────────────────────────────────

   (test-suite
    "Preprocessing expressions"

    (test-case "literal values are expressions"
      (check-not-false (redex-match? Iidy-Preprocess e (term null)))
      (check-not-false (redex-match? Iidy-Preprocess e (term (num 42))))
      (check-not-false (redex-match? Iidy-Preprocess e (term (str "hi")))))

    (test-case "seq is an expression"
      (check-not-false (redex-match? Iidy-Preprocess e
                         (term (seq ((num 1) (num 2) (num 3)))))))

    (test-case "obj-e is an expression"
      (check-not-false (redex-match? Iidy-Preprocess e
                         (term (obj-e (("a" (num 1)) ("b" (num 2))))))))

    (test-case "tpl is an expression"
      (check-not-false (redex-match? Iidy-Preprocess e
                         (term (tpl "Hello {{name}}")))))

    (test-case "var is an expression"
      (check-not-false (redex-match? Iidy-Preprocess e
                         (term (var ("myVar"))))))

    (test-case "var with dotted path"
      (check-not-false (redex-match? Iidy-Preprocess e
                         (term (var ("config" "region"))))))

    (test-case "if is an expression"
      (check-not-false (redex-match? Iidy-Preprocess e
                         (term (if (var ("flag")) (str "yes") (str "no"))))))

    (test-case "let is an expression"
      (check-not-false (redex-match? Iidy-Preprocess e
                         (term (let (("x" (num 10)) ("y" (num 20)))
                                 (var ("x")))))))

    (test-case "map is an expression"
      (check-not-false (redex-match? Iidy-Preprocess e
                         (term (map (var ("items")) (var ("item")) "item")))))

    (test-case "map-f is an expression"
      (check-not-false (redex-match? Iidy-Preprocess e
                         (term (map-f (var ("items")) (var ("item")) "item"
                                      (var ("item")))))))

    (test-case "concat is an expression"
      (check-not-false (redex-match? Iidy-Preprocess e
                         (term (concat ((arr ((num 1))) (arr ((num 2)))))))))

    (test-case "merge is an expression"
      (check-not-false (redex-match? Iidy-Preprocess e
                         (term (merge ((obj (("a" (num 1))))
                                       (obj (("b" (num 2))))))))))

    (test-case "eq is an expression"
      (check-not-false (redex-match? Iidy-Preprocess e
                         (term (eq (num 1) (num 1))))))

    (test-case "not is an expression"
      (check-not-false (redex-match? Iidy-Preprocess e
                         (term (not (bool #f))))))

    (test-case "split is an expression"
      (check-not-false (redex-match? Iidy-Preprocess e
                         (term (split (str ",") (str "a,b,c"))))))

    (test-case "join is an expression"
      (check-not-false (redex-match? Iidy-Preprocess e
                         (term (join (str ",") (arr ((str "a") (str "b"))))))))

    (test-case "concat-map is an expression"
      (check-not-false (redex-match? Iidy-Preprocess e
                         (term (concat-map (var ("items")) (var ("item")) "item")))))

    (test-case "merge-map is an expression"
      (check-not-false (redex-match? Iidy-Preprocess e
                         (term (merge-map (var ("items")) (var ("item")) "item")))))

    (test-case "map-list-to-hash is an expression"
      (check-not-false (redex-match? Iidy-Preprocess e
                         (term (map-list-to-hash (var ("items")) (var ("item")) "item")))))

    (test-case "map-values is an expression"
      (check-not-false (redex-match? Iidy-Preprocess e
                         (term (map-values (var ("items")) (var ("item")) "item")))))

    (test-case "group-by is an expression"
      (check-not-false (redex-match? Iidy-Preprocess e
                         (term (group-by (var ("items")) (var ("item")) "item")))))

    (test-case "from-pairs is an expression"
      (check-not-false (redex-match? Iidy-Preprocess e
                         (term (from-pairs (var ("pairs")))))))

    (test-case "to-yaml is an expression"
      (check-not-false (redex-match? Iidy-Preprocess e
                         (term (to-yaml (num 42))))))

    (test-case "parse-yaml is an expression"
      (check-not-false (redex-match? Iidy-Preprocess e
                         (term (parse-yaml (str "42"))))))

    (test-case "to-json is an expression"
      (check-not-false (redex-match? Iidy-Preprocess e
                         (term (to-json (num 42))))))

    (test-case "parse-json is an expression"
      (check-not-false (redex-match? Iidy-Preprocess e
                         (term (parse-json (str "42"))))))

    (test-case "escape is an expression"
      (check-not-false (redex-match? Iidy-Preprocess e
                         (term (escape (var ("x")))))))

    (test-case "expand is an expression"
      (check-not-false (redex-match? Iidy-Preprocess e
                         (term (expand (str "my-template")
                                       (obj (("param1" (num 1)))))))))

    (test-case "cfn is an expression"
      (check-not-false (redex-match? Iidy-Preprocess e
                         (term (cfn "!Ref" (str "MyResource"))))))))))
