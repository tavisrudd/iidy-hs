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
         "../semantics/eval.rkt"
         "../lang/jmespath.rkt"
         "../semantics/jmespath-eval.rkt")

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
                               ("y" (obj (("key" (str "y")) ("value" (num 2))))))))))

    (test-case "map-values with transformation accessing value"
      (eval-expect (term (map-values
                           (obj (("count" (num 5))))
                           (var ("item" "value"))
                           "item"))
                   (term ())
                   (term (obj (("count" (num 5)))))))

    (test-case "map-values on empty object"
      (eval-expect (term (map-values
                           (obj ())
                           (var ("item"))
                           "item"))
                   (term ())
                   (term (obj ())))))

   ;; ── GroupBy ────────────────────────────────────────────────────

   (test-suite
    "GroupBy (group-by)"

    (test-case "group by simple key"
      (eval-expect (term (group-by
                           (arr ((obj (("type" (str "a")) ("val" (num 1))))
                                 (obj (("type" (str "b")) ("val" (num 2))))
                                 (obj (("type" (str "a")) ("val" (num 3))))))
                           (var ("item" "type"))
                           "item"))
                   (term ())
                   (term (obj (("a" (arr ((obj (("type" (str "a")) ("val" (num 1))))
                                          (obj (("type" (str "a")) ("val" (num 3)))))))
                               ("b" (arr ((obj (("type" (str "b")) ("val" (num 2))))))))))))

    (test-case "group-by with all same key"
      (eval-expect (term (group-by
                           (arr ((num 1) (num 2) (num 3)))
                           (str "same")
                           "item"))
                   (term ())
                   (term (obj (("same" (arr ((num 1) (num 2) (num 3)))))))))

    (test-case "group-by with empty array"
      (eval-expect (term (group-by
                           (arr ())
                           (var ("item"))
                           "item"))
                   (term ())
                   (term (obj ()))))

    (test-case "group-by preserves first-seen key order"
      (eval-expect (term (group-by
                           (arr ((str "b1") (str "a1") (str "b2")))
                           ;; Use the first character as the group key
                           ;; Since we can't do substring, use a let to
                           ;; simulate: items whose equality groups them
                           (if (eq (var ("item")) (str "a1"))
                               (str "a")
                               (str "b"))
                           "item"))
                   (term ())
                   (term (obj (("b" (arr ((str "b1") (str "b2"))))
                               ("a" (arr ((str "a1"))))))))))

   ;; ── ConcatMap with filter ──────────────────────────────────────

   (test-suite
    "ConcatMap with filter (concat-map-f)"

    (test-case "concat-map-f filters then flattens"
      (eval-expect (term (concat-map-f
                           (arr ((arr ((num 1) (num 2)))
                                 (arr ())
                                 (arr ((num 3)))))
                           (var ("item"))
                           "item"
                           ;; Only keep non-empty arrays (arr is truthy)
                           (not (eq (var ("item")) (arr ())))))
                   (term ())
                   (term (arr ((num 1) (num 2) (num 3)))))))

   ;; ── MapListToHash with filter ──────────────────────────────────

   (test-suite
    "MapListToHash with filter (map-list-to-hash-f)"

    (test-case "map-list-to-hash-f filters then hashes"
      (eval-expect (term (map-list-to-hash-f
                           (arr ((str "a") (str "b") (str "c")))
                           (seq ((var ("item")) (num 1)))
                           "item"
                           (not (eq (var ("item")) (str "b")))))
                   (term ())
                   (term (obj (("a" (num 1)) ("c" (num 1))))))))

   ;; ── Nested / compound operations ──────────────────────────────

   (test-suite
    "Nested and compound operations"

    (test-case "map inside let"
      (eval-expect (term (let (("items" (arr ((num 10) (num 20)))))
                           (map (var ("items"))
                                (eq (var ("x")) (num 10))
                                "x")))
                   (term ())
                   (term (arr ((bool #t) (bool #f))))))

    (test-case "if inside map"
      (eval-expect (term (map (arr ((num 1) (num 2) (num 3)))
                              (if (eq (var ("item")) (num 2))
                                  (str "two")
                                  (str "other"))
                              "item"))
                   (term ())
                   (term (arr ((str "other") (str "two") (str "other"))))))

    (test-case "merge of dynamically-keyed mapped results"
      ;; Use from-pairs to create objects with dynamic keys from item values
      (eval-expect (term (merge-map
                           (arr ((str "a") (str "b")))
                           (from-pairs (seq ((seq ((var ("item")) (num 1))))))
                           "item"))
                   (term ())
                   (term (obj (("a" (num 1)) ("b" (num 1)))))))

    (test-case "let shadows work with nested scope"
      (eval-expect (term (let (("x" (num 1)))
                           (let (("x" (num 2)))
                             (var ("x")))))
                   (term ())
                   (term (num 2))))

    (test-case "concat of mapped results"
      (eval-expect (term (concat-map
                           (arr ((num 1) (num 2)))
                           (seq ((var ("item")) (var ("item"))))
                           "item"))
                   (term ())
                   (term (arr ((num 1) (num 1) (num 2) (num 2))))))

    (test-case "map with complex body expression"
      (eval-expect (term (map (arr ((str "hello") (str "world")))
                              (join (str "-")
                                    (split (str "l") (var ("item"))))
                              "item"))
                   (term ())
                   (term (arr ((str "he--o") (str "wor-d")))))))

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
                   (term (obj (("!Sub" (str "arn:aws:s3:::${Bucket}"))))))))

   ;; ── Template string ─────────────────────────────────────────────

   (test-suite
    "Template string (tpl)"

    (test-case "simple variable interpolation"
      (eval-expect (term (tpl "Hello, {{name}}!"))
                   (term (("name" (str "Alice"))))
                   (term (str "Hello, Alice!"))))

    (test-case "nested path interpolation"
      (eval-expect (term (tpl "Region: {{config.region}}"))
                   (term (("config" (obj (("region" (str "us-west-2")))))))
                   (term (str "Region: us-west-2"))))

    (test-case "multiple interpolations"
      (eval-expect (term (tpl "{{first}} {{last}}"))
                   (term (("first" (str "Jane")) ("last" (str "Doe"))))
                   (term (str "Jane Doe"))))

    (test-case "no interpolation — literal passthrough"
      (eval-expect (term (tpl "plain text"))
                   (term ())
                   (term (str "plain text"))))

    (test-case "missing variable produces empty"
      (eval-expect (term (tpl "val={{missing}}"))
                   (term ())
                   (term (str "val="))))

    (test-case "number interpolation"
      (eval-expect (term (tpl "count: {{n}}"))
                   (term (("n" (num 42))))
                   (term (str "count: 42"))))

    (test-case "boolean interpolation"
      (eval-expect (term (tpl "flag: {{f}}"))
                   (term (("f" (bool #t))))
                   (term (str "flag: true")))))

   ;; ── Variable with dot-query ──────────────────────────────────────

   (test-suite
    "Variable with dot-query (var-q)"

    (test-case "single path traversal"
      (eval-expect (term (var-q ("config") "db.host"))
                   (term (("config" (obj (("db" (obj (("host" (str "localhost"))))))))))
                   (term (str "localhost"))))

    (test-case "comma-separated key selection"
      (eval-expect (term (var-q ("obj") "a, c"))
                   (term (("obj" (obj (("a" (num 1)) ("b" (num 2)) ("c" (num 3)))))))
                   (term (obj (("a" (num 1)) ("c" (num 3)))))))

    (test-case "comma-separated with missing key → null"
      (eval-expect (term (var-q ("obj") "a, missing"))
                   (term (("obj" (obj (("a" (num 1)))))))
                   (term (obj (("a" (num 1)) ("missing" null))))))

    (test-case "single key selection"
      (eval-expect (term (var-q ("data") "name"))
                   (term (("data" (obj (("name" (str "Alice")) ("age" (num 30)))))))
                   (term (str "Alice")))))

   ;; ── JMESPath integration (tested at sub-language level) ──────────

   (test-suite
    "JMESPath integration"

    ;; These tests verify JMESPath evaluation directly via the
    ;; jmespath-eval module. The E-Var-J eval rule is a specification
    ;; only (requires JMESPath string parsing).

    (test-case "jeval field access integrates with core values"
      (check-equal?
       (term (jeval (jfield "name") (obj (("name" (str "test"))))))
       (term (str "test"))))

    (test-case "jeval projection integrates with core values"
      (check-equal?
       (term (jeval (jproj jwildcard (jfield "name"))
                    (arr ((obj (("name" (str "a")))) (obj (("name" (str "b"))))))))
       (term (arr ((str "a") (str "b"))))))

    (test-case "jeval filter integrates with core values"
      (check-equal?
       (term (jeval (jfilter (jcmp > (jfield "v") (jlit (num 1))) jidentity)
                    (arr ((obj (("v" (num 1)))) (obj (("v" (num 2))))))))
       (term (arr ((obj (("v" (num 2))))))))))

   ;; ── Serialization ────────────────────────────────────────────────

   (test-suite
    "Serialization (to-yaml, to-json)"

    (test-case "to-yaml string"
      (eval-expect (term (to-yaml (str "hello")))
                   (term ())
                   (term (str "hello"))))

    (test-case "to-yaml number"
      (eval-expect (term (to-yaml (num 42)))
                   (term ())
                   (term (str "42"))))

    (test-case "to-yaml bool"
      (eval-expect (term (to-yaml (bool #t)))
                   (term ())
                   (term (str "true"))))

    (test-case "to-yaml null"
      (eval-expect (term (to-yaml null))
                   (term ())
                   (term (str "null"))))

    (test-case "to-json string"
      (eval-expect (term (to-json (str "hello")))
                   (term ())
                   (term (str "\"hello\""))))

    (test-case "to-json number"
      (eval-expect (term (to-json (num 42)))
                   (term ())
                   (term (str "42"))))

    (test-case "to-json bool true"
      (eval-expect (term (to-json (bool #t)))
                   (term ())
                   (term (str "true"))))

    (test-case "to-json null"
      (eval-expect (term (to-json null))
                   (term ())
                   (term (str "null"))))

    (test-case "to-json array"
      (eval-expect (term (to-json (arr ((num 1) (num 2)))))
                   (term ())
                   (term (str "[1,2]"))))

    (test-case "to-json object"
      (eval-expect (term (to-json (obj (("a" (num 1))))))
                   (term ())
                   (term (str "{\"a\":1}"))))

    (test-case "to-yaml evaluates subexpression"
      (eval-expect (term (to-yaml (var ("x"))))
                   (term (("x" (num 99))))
                   (term (str "99"))))

    (test-case "to-json evaluates subexpression"
      (eval-expect (term (to-json (var ("x"))))
                   (term (("x" (str "hi"))))
                   (term (str "\"hi\"")))))

   ;; ── Helper metafunction tests ────────────────────────────────────

   (test-suite
    "Helper metafunctions"

    (test-case "env-to-obj converts environment to object"
      (check-equal?
       (term (env-to-obj (("a" (num 1)) ("b" (str "two")))))
       (term (obj (("a" (num 1)) ("b" (str "two")))))))

    (test-case "env-to-obj empty environment"
      (check-equal?
       (term (env-to-obj ()))
       (term (obj ()))))

    (test-case "dot-query single path"
      (check-equal?
       (term (dot-query "host" (obj (("host" (str "localhost")) ("port" (num 5432))))))
       (term (str "localhost"))))

    (test-case "dot-query nested path"
      (check-equal?
       (term (dot-query "db.host" (obj (("db" (obj (("host" (str "localhost")))))))))
       (term (str "localhost"))))

    (test-case "dot-query comma-separated keys"
      (check-equal?
       (term (dot-query "a, c" (obj (("a" (num 1)) ("b" (num 2)) ("c" (num 3))))))
       (term (obj (("a" (num 1)) ("c" (num 3)))))))

    (test-case "val->json nested structure"
      (check-equal?
       (val->json (term (obj (("items" (arr ((num 1) (bool #t) null)))))))
       "{\"items\":[1,true,null]}")))))
