#lang racket/base
;; Snapshot generator for spec-implementation conformance testing
;;
;; Evaluates key drift-point behaviors through the PLT Redex spec and
;; writes deterministic test vectors to snapshot.json. The Haskell
;; conformance test reads this file (no Racket dependency needed).
;;
;; Regenerate: cd spec && nix develop --command racket snapshot.rkt

(require redex/reduction-semantics
         racket/match
         racket/port
         racket/list
         racket/system
         json
         "lang/core.rkt"
         "lang/preprocessing.rkt"
         "semantics/truthiness.rkt"
         "semantics/merge.rkt"
         "semantics/env.rkt"
         "semantics/eval.rkt")


;; ── Redex value → jsexpr conversion ──────────────────────────────
;; Uses sorted-hasheq for deterministic JSON output (Racket hasheq
;; iteration order is unspecified and could change across versions).

(define (sorted-hasheq . pairs)
  (make-hasheq (sort pairs string<? #:key (λ (p) (symbol->string (car p))))))

(define (val->jsexpr v)
  (match v
    ['null                                            'null]
    [`(bool #t)                                       #t]
    [`(bool #f)                                       #f]
    [`(num ,n)                                        n]
    [`(str ,s)                                        s]
    [`(arr ,items)                                    (map val->jsexpr items)]
    [`(obj ,pairs)
     (apply sorted-hasheq
      (map (λ (p) (cons (string->symbol (car p))
                        (val->jsexpr (cadr p))))
           pairs))]
    ['unbound                                         'null]
    [other (error 'val->jsexpr "unexpected: ~a" other)]))


;; ── Section 1: Truthiness ────────────────────────────────────────
;; 13 input values × 3 truthiness variants

(define truthiness-inputs
  '(null
    (bool #f) (bool #t)
    (str "") (str "hello")
    (num 0) (num 1) (num -1) (num 3.14)
    (arr ()) (arr ((num 1)))
    (obj ()) (obj (("a" (num 1))))))

;; iidy OValue truthiness: 0 is falsy
(define truthiness-vectors
  (map (λ (v)
         (sorted-hasheq (cons 'input (val->jsexpr v))
                        (cons 'expected (term (truthy ,v)))))
       truthiness-inputs))

;; Handlebars truthiness: all numbers truthy (including 0)
(define hbs-truthiness-vectors
  (map (λ (v)
         (sorted-hasheq (cons 'input (val->jsexpr v))
                        (cons 'expected (term (truthy/hbs ,v)))))
       truthiness-inputs))

;; JMESPath truthiness: all numbers truthy (including 0)
(define jmespath-truthiness-vectors
  (map (λ (v)
         (sorted-hasheq (cons 'input (val->jsexpr v))
                        (cons 'expected (term (truthy/jmespath ,v)))))
       truthiness-inputs))


;; ── Section 2: Merge ─────────────────────────────────────────────
;; 3 merge scenarios (key-order tested in Haskell-only test)

(define merge-vectors
  (list
   ;; Overlay wins on collision, base order preserved, new keys appended
   (let ([result (term (merge-objs
                        (obj (("a" (num 1)) ("b" (num 2)) ("c" (num 3))))
                        (obj (("b" (num 99)) ("d" (num 4))))))])
     (sorted-hasheq
      (cons 'name "overlay wins, base order preserved")
      (cons 'base (val->jsexpr (term (obj (("a" (num 1)) ("b" (num 2)) ("c" (num 3)))))))
      (cons 'overlay (val->jsexpr (term (obj (("b" (num 99)) ("d" (num 4)))))))
      (cons 'expected (val->jsexpr result))))

   ;; Disjoint keys: simple concatenation
   (let ([result (term (merge-objs
                        (obj (("x" (num 10))))
                        (obj (("y" (num 20))))))])
     (sorted-hasheq
      (cons 'name "disjoint keys")
      (cons 'base (val->jsexpr (term (obj (("x" (num 10)))))))
      (cons 'overlay (val->jsexpr (term (obj (("y" (num 20)))))))
      (cons 'expected (val->jsexpr result))))

   ;; Empty base: overlay becomes result
   (let ([result (term (merge-objs
                        (obj ())
                        (obj (("a" (num 1)) ("b" (num 2))))))])
     (sorted-hasheq
      (cons 'name "empty base")
      (cons 'base (val->jsexpr (term (obj ()))))
      (cons 'overlay (val->jsexpr (term (obj (("a" (num 1)) ("b" (num 2)))))))
      (cons 'expected (val->jsexpr result))))))


;; ── Section 3: Path resolution ───────────────────────────────────
;; 5 path lookups through nested structures

(define path-env
  '(("config" (obj (("db" (obj (("host" (str "localhost"))
                                ("port" (num 5432))))))))
    ("items" (arr ((num 10) (num 20) (num 30))))
    ("name" (str "test"))
    ("nested" (arr ((obj (("id" (str "first")))) (obj (("id" (str "second")))))))))

(define path-vectors
  (list
   (let ([result (term (resolve-path ("config" "db" "host") ,path-env))])
     (sorted-hasheq
      (cons 'name "nested object traversal")
      (cons 'path '("config" "db" "host"))
      (cons 'expected (val->jsexpr result))))

   (let ([result (term (resolve-path ("items" "1") ,path-env))])
     (sorted-hasheq
      (cons 'name "array index")
      (cons 'path '("items" "1"))
      (cons 'expected (val->jsexpr result))))

   (let ([result (term (resolve-path ("nonexistent") ,path-env))])
     (sorted-hasheq
      (cons 'name "missing key")
      (cons 'path '("nonexistent"))
      (cons 'expected (val->jsexpr result))))

   (let ([result (term (resolve-path ("name") ,path-env))])
     (sorted-hasheq
      (cons 'name "single segment")
      (cons 'path '("name"))
      (cons 'expected (val->jsexpr result))))

   (let ([result (term (resolve-path ("nested" "0" "id") ,path-env))])
     (sorted-hasheq
      (cons 'name "nested into array object")
      (cons 'path '("nested" "0" "id"))
      (cons 'expected (val->jsexpr result))))))


;; ── Section 4: Escape ────────────────────────────────────────────
;; 4 escape-to-raw cases

(define escape-vectors
  (list
   (let ([result (term (escape-to-raw (num 42)))])
     (sorted-hasheq
      (cons 'name "value passthrough")
      (cons 'input_type "value")
      (cons 'input_value 42)
      (cons 'expected (val->jsexpr result))))

   (let ([result (term (escape-to-raw
                        (obj-e (("a" (num 1)) ("b" (str "hello"))))))])
     (sorted-hasheq
      (cons 'name "nested object expression")
      (cons 'input_type "object")
      (cons 'input_value (val->jsexpr (term (obj (("a" (num 1)) ("b" (str "hello")))))))
      (cons 'expected (val->jsexpr result))))

   (let ([result (term (escape-to-raw (tpl "{{foo.bar}}")))])
     (sorted-hasheq
      (cons 'name "template becomes literal string")
      (cons 'input_type "template")
      (cons 'input_value "{{foo.bar}}")
      (cons 'expected (val->jsexpr result))))

   (let ([result (term (escape-to-raw (not (bool #t))))])
     (sorted-hasheq
      (cons 'name "preprocessing tag becomes sentinel")
      (cons 'input_type "tag")
      (cons 'input_value 'null)
      (cons 'expected (val->jsexpr result))))))


;; ── Section 5: MapValues binding ─────────────────────────────────
;; Verify the {key, value} binding structure

(define map-values-binding-vectors
  (list
   (sorted-hasheq
    (cons 'name "string key, numeric value")
    (cons 'key "alpha")
    (cons 'value 42)
    (cons 'expected_binding
          (val->jsexpr (term (obj (("key" (str "alpha")) ("value" (num 42))))))))

   (sorted-hasheq
    (cons 'name "string key, object value")
    (cons 'key "settings")
    (cons 'value (sorted-hasheq (cons 'host "localhost")))
    (cons 'expected_binding
          (val->jsexpr (term (obj (("key" (str "settings"))
                                  ("value" (obj (("host" (str "localhost")))))))))))))


;; ── Assemble and write ───────────────────────────────────────────

(define snapshot
  (sorted-hasheq
   (cons 'generated "2026-03-03")
   (cons 'generator "spec/snapshot.rkt")
   (cons 'sections
         (sorted-hasheq
          (cons 'truthiness            truthiness-vectors)
          (cons 'truthiness_handlebars hbs-truthiness-vectors)
          (cons 'truthiness_jmespath   jmespath-truthiness-vectors)
          (cons 'merge                 merge-vectors)
          (cons 'path_resolution       path-vectors)
          (cons 'escape                escape-vectors)
          (cons 'map_values_binding    map-values-binding-vectors)))))

(define out-path "snapshot.json")

;; Write compact JSON then pretty-print with jq for deterministic,
;; human-readable output (jq preserves key order from input).
(call-with-output-file out-path
  (λ (port)
    (write-json snapshot port)
    (newline port))
  #:exists 'replace)

(define jq-rc
  (system (format "jq --indent 4 . ~a > ~a.tmp && mv ~a.tmp ~a"
                  out-path out-path out-path out-path)))
(unless jq-rc
  (error 'snapshot "jq formatting failed — is jq in PATH?"))

(printf "Wrote ~a (~a bytes)\n" out-path (file-size out-path))
