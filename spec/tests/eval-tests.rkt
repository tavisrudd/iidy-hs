#lang racket/base
;; Evaluation judgment tests
;;
;; Tests the big-step eval judgment against expected outputs.
;; Organized by tag form.

(require redex/reduction-semantics
         rackunit
         "../lang/core.rkt"
         "../lang/preprocessing.rkt"
         "../semantics/truthiness.rkt"
         "../semantics/env.rkt"
         "../semantics/merge.rkt"
         "../semantics/eval.rkt")

(provide eval-tests)

;; Helper: assert that evaluation produces exactly one result
(define (eval-expect e σ expected)
  (define results (judgment-holds (eval ,e ,σ v) v))
  (check-equal? (length results) 1
                (format "Expected exactly 1 result for ~a, got ~a: ~a"
                        e (length results) results))
  (when (= (length results) 1)
    (check-equal? (car results) expected
                  (format "Evaluating ~a" e))))

(define eval-tests
  (test-suite
   "Evaluation judgment"

   ;; ── Literal evaluation ────────────────────────────────────────

   (test-suite
    "Literals"

    (test-case "null evaluates to null"
      (eval-expect (term null) (term ()) (term null)))

    (test-case "bool evaluates to bool"
      (eval-expect (term (bool #t)) (term ()) (term (bool #t)))
      (eval-expect (term (bool #f)) (term ()) (term (bool #f))))

    (test-case "number evaluates to number"
      (eval-expect (term (num 42)) (term ()) (term (num 42))))

    (test-case "string evaluates to string"
      (eval-expect (term (str "hello")) (term ()) (term (str "hello"))))

    (test-case "array evaluates to array"
      (eval-expect (term (arr ((num 1) (num 2))))
                   (term ())
                   (term (arr ((num 1) (num 2))))))

    (test-case "object evaluates to object"
      (eval-expect (term (obj (("a" (num 1)))))
                   (term ())
                   (term (obj (("a" (num 1))))))))

   ;; ── Sequence evaluation ───────────────────────────────────────

   (test-suite
    "Sequence (seq)"

    (test-case "empty sequence"
      (eval-expect (term (seq ())) (term ()) (term (arr ()))))

    (test-case "sequence evaluates elements"
      (eval-expect (term (seq ((num 1) (str "two") (bool #t))))
                   (term ())
                   (term (arr ((num 1) (str "two") (bool #t)))))))

   ;; ── Object expression evaluation ──────────────────────────────

   (test-suite
    "Object expression (obj-e)"

    (test-case "empty object expression"
      (eval-expect (term (obj-e ())) (term ()) (term (obj ()))))

    (test-case "object expression evaluates values"
      (eval-expect (term (obj-e (("name" (str "Alice")) ("age" (num 30)))))
                   (term ())
                   (term (obj (("name" (str "Alice")) ("age" (num 30))))))))

   ;; ── Variable lookup ───────────────────────────────────────────

   (test-suite
    "Variable lookup (var)"

    (test-case "simple variable lookup"
      (eval-expect (term (var ("x")))
                   (term (("x" (num 42))))
                   (term (num 42))))

    (test-case "dotted path lookup"
      (eval-expect (term (var ("config" "region")))
                   (term (("config" (obj (("region" (str "us-east-1")))))))
                   (term (str "us-east-1"))))

    (test-case "nested dotted path"
      (eval-expect (term (var ("a" "b" "c")))
                   (term (("a" (obj (("b" (obj (("c" (num 99))))))))))
                   (term (num 99))))

    (test-case "array index access"
      (eval-expect (term (var ("items" "0")))
                   (term (("items" (arr ((str "first") (str "second"))))))
                   (term (str "first"))))

    (test-case "shadowed variable uses most recent"
      (eval-expect (term (var ("x")))
                   (term (("x" (num 1)) ("x" (num 2))))
                   (term (num 2)))))

   ;; ── Conditional ───────────────────────────────────────────────

   (test-suite
    "Conditional (if)"

    (test-case "true condition takes then branch"
      (eval-expect (term (if (bool #t) (str "yes") (str "no")))
                   (term ())
                   (term (str "yes"))))

    (test-case "false condition takes else branch"
      (eval-expect (term (if (bool #f) (str "yes") (str "no")))
                   (term ())
                   (term (str "no"))))

    (test-case "truthy number takes then branch"
      (eval-expect (term (if (num 1) (str "yes") (str "no")))
                   (term ())
                   (term (str "yes"))))

    (test-case "zero is falsy — takes else branch"
      (eval-expect (term (if (num 0) (str "yes") (str "no")))
                   (term ())
                   (term (str "no"))))

    (test-case "non-empty string is truthy"
      (eval-expect (term (if (str "ok") (str "yes") (str "no")))
                   (term ())
                   (term (str "yes"))))

    (test-case "empty string is falsy"
      (eval-expect (term (if (str "") (str "yes") (str "no")))
                   (term ())
                   (term (str "no"))))

    (test-case "null is falsy"
      (eval-expect (term (if null (str "yes") (str "no")))
                   (term ())
                   (term (str "no"))))

    (test-case "if with variable lookup as condition"
      (eval-expect (term (if (var ("flag"))
                             (str "enabled")
                             (str "disabled")))
                   (term (("flag" (bool #t))))
                   (term (str "enabled")))))

   ;; ── Let binding ───────────────────────────────────────────────

   (test-suite
    "Let binding (let)"

    (test-case "simple let binding"
      (eval-expect (term (let (("x" (num 10))) (var ("x"))))
                   (term ())
                   (term (num 10))))

    (test-case "let with multiple bindings"
      (eval-expect (term (let (("x" (num 10)) ("y" (num 20)))
                           (seq ((var ("x")) (var ("y"))))))
                   (term ())
                   (term (arr ((num 10) (num 20))))))

    (test-case "let bindings are sequential — later sees earlier"
      (eval-expect (term (let (("x" (num 5))
                               ("y" (var ("x"))))
                           (var ("y"))))
                   (term ())
                   (term (num 5))))

    (test-case "let shadows outer scope"
      (eval-expect (term (let (("x" (num 99)))
                           (var ("x"))))
                   (term (("x" (num 1))))
                   (term (num 99)))))

   ;; ── Equality ──────────────────────────────────────────────────

   (test-suite
    "Equality (eq)"

    (test-case "equal numbers"
      (eval-expect (term (eq (num 1) (num 1)))
                   (term ())
                   (term (bool #t))))

    (test-case "unequal numbers"
      (eval-expect (term (eq (num 1) (num 2)))
                   (term ())
                   (term (bool #f))))

    (test-case "equal strings"
      (eval-expect (term (eq (str "a") (str "a")))
                   (term ())
                   (term (bool #t))))

    (test-case "unequal strings"
      (eval-expect (term (eq (str "a") (str "b")))
                   (term ())
                   (term (bool #f))))

    (test-case "different types are unequal"
      (eval-expect (term (eq (num 1) (str "1")))
                   (term ())
                   (term (bool #f))))

    (test-case "null equals null"
      (eval-expect (term (eq null null))
                   (term ())
                   (term (bool #t)))))

   ;; ── Not ───────────────────────────────────────────────────────

   (test-suite
    "Negation (not)"

    (test-case "not true is false"
      (eval-expect (term (not (bool #t)))
                   (term ())
                   (term (bool #f))))

    (test-case "not false is true"
      (eval-expect (term (not (bool #f)))
                   (term ())
                   (term (bool #t))))

    (test-case "not null is true (null is falsy)"
      (eval-expect (term (not null))
                   (term ())
                   (term (bool #t))))

    (test-case "not 0 is true (zero is falsy in iidy)"
      (eval-expect (term (not (num 0)))
                   (term ())
                   (term (bool #t))))

    (test-case "not non-zero is false"
      (eval-expect (term (not (num 42)))
                   (term ())
                   (term (bool #f)))))

   ;; ── Split ─────────────────────────────────────────────────────

   (test-suite
    "Split (split)"

    (test-case "split by comma"
      (eval-expect (term (split (str ",") (str "a,b,c")))
                   (term ())
                   (term (arr ((str "a") (str "b") (str "c"))))))

    (test-case "split with no delimiter occurrence"
      (eval-expect (term (split (str ",") (str "hello")))
                   (term ())
                   (term (arr ((str "hello"))))))

    (test-case "split empty string"
      (eval-expect (term (split (str ",") (str "")))
                   (term ())
                   (term (arr ((str "")))))))

   ;; ── Join ──────────────────────────────────────────────────────

   (test-suite
    "Join (join)"

    (test-case "join strings by comma"
      (eval-expect (term (join (str ",") (arr ((str "a") (str "b") (str "c")))))
                   (term ())
                   (term (str "a,b,c"))))

    (test-case "join single element"
      (eval-expect (term (join (str ",") (arr ((str "only")))))
                   (term ())
                   (term (str "only"))))

    (test-case "join empty array"
      (eval-expect (term (join (str ",") (arr ())))
                   (term ())
                   (term (str "")))))

   ;; ── Concat ────────────────────────────────────────────────────

   (test-suite
    "Concat (concat)"

    (test-case "concatenate two arrays"
      (eval-expect (term (concat ((arr ((num 1) (num 2)))
                                   (arr ((num 3) (num 4))))))
                   (term ())
                   (term (arr ((num 1) (num 2) (num 3) (num 4))))))

    (test-case "concatenate with empty"
      (eval-expect (term (concat ((arr ()) (arr ((num 1))))))
                   (term ())
                   (term (arr ((num 1))))))

    (test-case "concatenate three arrays"
      (eval-expect (term (concat ((arr ((num 1)))
                                   (arr ((num 2)))
                                   (arr ((num 3))))))
                   (term ())
                   (term (arr ((num 1) (num 2) (num 3)))))))

   ;; ── Merge ─────────────────────────────────────────────────────

   (test-suite
    "Merge (merge)"

    (test-case "merge two disjoint objects"
      (eval-expect (term (merge ((obj (("a" (num 1))))
                                  (obj (("b" (num 2)))))))
                   (term ())
                   (term (obj (("a" (num 1)) ("b" (num 2)))))))

    (test-case "merge with overlay — right wins"
      (eval-expect (term (merge ((obj (("a" (num 1)) ("b" (num 2))))
                                  (obj (("b" (num 99)))))))
                   (term ())
                   (term (obj (("a" (num 1)) ("b" (num 99)))))))

    (test-case "merge preserves base key order"
      (eval-expect (term (merge ((obj (("z" (num 1)) ("a" (num 2))))
                                  (obj (("m" (num 3)))))))
                   (term ())
                   (term (obj (("z" (num 1)) ("a" (num 2)) ("m" (num 3)))))))

    (test-case "merge three objects"
      (eval-expect (term (merge ((obj (("a" (num 1))))
                                  (obj (("b" (num 2))))
                                  (obj (("c" (num 3)))))))
                   (term ())
                   (term (obj (("a" (num 1)) ("b" (num 2)) ("c" (num 3))))))))

   ;; ── FromPairs ─────────────────────────────────────────────────

   (test-suite
    "FromPairs (from-pairs)"

    (test-case "pairs to object"
      (eval-expect (term (from-pairs (arr ((arr ((str "a") (num 1)))
                                            (arr ((str "b") (num 2)))))))
                   (term ())
                   (term (obj (("a" (num 1)) ("b" (num 2))))))))

   ;; ── Map ──────────────────────────────────────────────────────

   (test-suite
    "Map (map)"

    (test-case "map over empty array"
      (eval-expect (term (map (arr ()) (var ("item")) "item"))
                   (term ())
                   (term (arr ()))))

    (test-case "map doubles numbers"
      (eval-expect (term (map (arr ((num 1) (num 2) (num 3)))
                              (eq (var ("item")) (num 2))
                              "item"))
                   (term ())
                   (term (arr ((bool #f) (bool #t) (bool #f))))))

    (test-case "map with custom var name"
      (eval-expect (term (map (arr ((str "a") (str "b")))
                              (var ("x"))
                              "x"))
                   (term ())
                   (term (arr ((str "a") (str "b"))))))

    (test-case "map template accesses outer scope"
      (eval-expect (term (map (arr ((num 1) (num 2)))
                              (eq (var ("item")) (var ("target")))
                              "item"))
                   (term (("target" (num 2))))
                   (term (arr ((bool #f) (bool #t)))))))

   ;; ── Map with filter ──────────────────────────────────────────

   (test-suite
    "Map with filter (map-f)"

    (test-case "filter keeps matching items"
      (eval-expect (term (map-f (arr ((num 1) (num 2) (num 3)))
                                (var ("item"))
                                "item"
                                (not (eq (var ("item")) (num 2)))))
                   (term ())
                   (term (arr ((num 1) (num 3))))))

    (test-case "filter with all passing"
      (eval-expect (term (map-f (arr ((num 1) (num 2)))
                                (var ("item"))
                                "item"
                                (bool #t)))
                   (term ())
                   (term (arr ((num 1) (num 2))))))

    (test-case "filter with none passing"
      (eval-expect (term (map-f (arr ((num 1) (num 2)))
                                (var ("item"))
                                "item"
                                (bool #f)))
                   (term ())
                   (term (arr ())))))

   ;; ── ConcatMap ────────────────────────────────────────────────

   (test-suite
    "ConcatMap (concat-map)"

    (test-case "concat-map flattens mapped arrays"
      (eval-expect (term (concat-map
                           (arr ((arr ((num 1) (num 2)))
                                 (arr ((num 3)))))
                           (var ("item"))
                           "item"))
                   (term ())
                   (term (arr ((num 1) (num 2) (num 3)))))))

   ;; ── MergeMap ─────────────────────────────────────────────────

   (test-suite
    "MergeMap (merge-map)"

    (test-case "merge-map merges mapped objects"
      (eval-expect (term (merge-map
                           (arr ((obj (("a" (num 1))))
                                 (obj (("b" (num 2))))))
                           (var ("item"))
                           "item"))
                   (term ())
                   (term (obj (("a" (num 1)) ("b" (num 2))))))))

   ;; ── MapListToHash ────────────────────────────────────────────

   (test-suite
    "MapListToHash (map-list-to-hash)"

    (test-case "map items to key-value pairs"
      (eval-expect (term (map-list-to-hash
                           (arr ((str "a") (str "b")))
                           (seq ((var ("item")) (num 1)))
                           "item"))
                   (term ())
                   (term (obj (("a" (num 1)) ("b" (num 1))))))))

   ;; ── MapValues ────────────────────────────────────────────────

   (test-suite
    "MapValues (map-values)"

    (test-case "transform object values"
      (eval-expect (term (map-values
                           (obj (("x" (num 1)) ("y" (num 2))))
                           (var ("item"))
                           "item"))
                   (term ())
                   ;; Each item is {key: k, value: v}
                   (term (obj (("x" (obj (("key" (str "x")) ("value" (num 1)))))
                               ("y" (obj (("key" (str "y")) ("value" (num 2)))))))))))

   ;; ── Escape ────────────────────────────────────────────────────

   (test-suite
    "Escape (escape)"

    (test-case "escape a literal passes through"
      (eval-expect (term (escape (num 42)))
                   (term ())
                   (term (num 42))))

    (test-case "escape an object passes through"
      (eval-expect (term (escape (obj (("a" (num 1))))))
                   (term ())
                   (term (obj (("a" (num 1)))))))

    (test-case "escape an array passes through"
      (eval-expect (term (escape (arr ((num 1) (num 2)))))
                   (term ())
                   (term (arr ((num 1) (num 2)))))))

   ;; ── CloudFormation pass-through ───────────────────────────────

   (test-suite
    "CloudFormation (cfn)"

    (test-case "Ref wraps as object"
      (eval-expect (term (cfn "!Ref" (str "MyResource")))
                   (term ())
                   (term (obj (("!Ref" (str "MyResource")))))))

    (test-case "Sub wraps as object"
      (eval-expect (term (cfn "!Sub" (str "arn:aws:s3:::${Bucket}")))
                   (term ())
                   (term (obj (("!Sub" (str "arn:aws:s3:::${Bucket}"))))))))))
