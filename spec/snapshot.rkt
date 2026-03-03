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
         json
         "lang/core.rkt"
         "lang/preprocessing.rkt"
         "semantics/truthiness.rkt"
         "semantics/merge.rkt"
         "semantics/env.rkt"
         "semantics/eval.rkt")


;; ── Redex value → jsexpr conversion ──────────────────────────────

(define (val->jsexpr v)
  (match v
    ['null                                            'null]
    [`(bool #t)                                       #t]
    [`(bool #f)                                       #f]
    [`(num ,n)                                        n]
    [`(str ,s)                                        s]
    [`(arr ,items)                                    (map val->jsexpr items)]
    [`(obj ,pairs)
     (make-hasheq
      (map (λ (p) (cons (string->symbol (car p))
                        (val->jsexpr (cadr p))))
           pairs))]
    ['unbound                                         'null]
    [other (error 'val->jsexpr "unexpected: ~a" other)]))


;; ── Section 1: Truthiness ────────────────────────────────────────
;; 13 input values → boolean (iidy OValue truthiness, where 0 is falsy)

(define truthiness-inputs
  '(null
    (bool #f) (bool #t)
    (str "") (str "hello")
    (num 0) (num 1) (num -1) (num 3.14)
    (arr ()) (arr ((num 1)))
    (obj ()) (obj (("a" (num 1))))))

(define truthiness-vectors
  (map (λ (v)
         (hasheq 'input (val->jsexpr v)
                 'expected (term (truthy ,v))))
       truthiness-inputs))


;; ── Section 2: Merge ─────────────────────────────────────────────
;; 3 merge scenarios with key-order preservation

(define merge-vectors
  (list
   ;; Overlay wins on collision, base order preserved, new keys appended
   (let ([result (term (merge-objs
                        (obj (("a" (num 1)) ("b" (num 2)) ("c" (num 3))))
                        (obj (("b" (num 99)) ("d" (num 4))))))])
     (hasheq 'name "overlay wins, base order preserved"
             'base (val->jsexpr (term (obj (("a" (num 1)) ("b" (num 2)) ("c" (num 3))))))
             'overlay (val->jsexpr (term (obj (("b" (num 99)) ("d" (num 4))))))
             'expected (val->jsexpr result)))

   ;; Disjoint keys: simple concatenation
   (let ([result (term (merge-objs
                        (obj (("x" (num 10))))
                        (obj (("y" (num 20))))))])
     (hasheq 'name "disjoint keys"
             'base (val->jsexpr (term (obj (("x" (num 10))))))
             'overlay (val->jsexpr (term (obj (("y" (num 20))))))
             'expected (val->jsexpr result)))

   ;; Empty base: overlay becomes result
   (let ([result (term (merge-objs
                        (obj ())
                        (obj (("a" (num 1)) ("b" (num 2))))))])
     (hasheq 'name "empty base"
             'base (val->jsexpr (term (obj ())))
             'overlay (val->jsexpr (term (obj (("a" (num 1)) ("b" (num 2))))))
             'expected (val->jsexpr result)))))


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
   ;; Nested object traversal
   (let ([result (term (resolve-path ("config" "db" "host") ,path-env))])
     (hasheq 'name "nested object traversal"
             'path '("config" "db" "host")
             'expected (val->jsexpr result)))

   ;; Array index
   (let ([result (term (resolve-path ("items" "1") ,path-env))])
     (hasheq 'name "array index"
             'path '("items" "1")
             'expected (val->jsexpr result)))

   ;; Missing key → unbound (null in JSON)
   (let ([result (term (resolve-path ("nonexistent") ,path-env))])
     (hasheq 'name "missing key"
             'path '("nonexistent")
             'expected (val->jsexpr result)))

   ;; Single segment
   (let ([result (term (resolve-path ("name") ,path-env))])
     (hasheq 'name "single segment"
             'path '("name")
             'expected (val->jsexpr result)))

   ;; Nested into array object
   (let ([result (term (resolve-path ("nested" "0" "id") ,path-env))])
     (hasheq 'name "nested into array object"
             'path '("nested" "0" "id")
             'expected (val->jsexpr result)))))


;; ── Section 4: Escape ────────────────────────────────────────────
;; 4 escape-to-raw cases

(define escape-vectors
  (list
   ;; Value passthrough
   (let ([result (term (escape-to-raw (num 42)))])
     (hasheq 'name "value passthrough"
             'input_type "value"
             'input_value 42
             'expected (val->jsexpr result)))

   ;; Nested object expression
   (let ([result (term (escape-to-raw
                        (obj-e (("a" (num 1)) ("b" (str "hello"))))))])
     (hasheq 'name "nested object expression"
             'input_type "object"
             'input_value (val->jsexpr (term (obj (("a" (num 1)) ("b" (str "hello"))))))
             'expected (val->jsexpr result)))

   ;; Template becomes literal string
   (let ([result (term (escape-to-raw (tpl "{{foo.bar}}")))])
     (hasheq 'name "template becomes literal string"
             'input_type "template"
             'input_value "{{foo.bar}}"
             'expected (val->jsexpr result)))

   ;; Preprocessing tag → sentinel
   (let ([result (term (escape-to-raw (not (bool #t))))])
     (hasheq 'name "preprocessing tag becomes sentinel"
             'input_type "tag"
             'input_value 'null
             'expected (val->jsexpr result)))))


;; ── Section 5: MapValues binding ─────────────────────────────────
;; Verify the {key, value} binding structure

(define map-values-binding-vectors
  (list
   ;; Binding for string key, numeric value
   (hasheq 'name "string key, numeric value"
           'key "alpha"
           'value 42
           'expected_binding
           (val->jsexpr (term (obj (("key" (str "alpha")) ("value" (num 42)))))))

   ;; Binding for string key, object value
   (hasheq 'name "string key, object value"
           'key "settings"
           'value (hasheq 'host "localhost")
           'expected_binding
           (val->jsexpr (term (obj (("key" (str "settings"))
                                   ("value" (obj (("host" (str "localhost"))))))))))))


;; ── Assemble and write ───────────────────────────────────────────

(define snapshot
  (hasheq 'generated "2026-03-03"
          'generator "spec/snapshot.rkt"
          'sections
          (hasheq 'truthiness       truthiness-vectors
                  'merge            merge-vectors
                  'path_resolution  path-vectors
                  'escape           escape-vectors
                  'map_values_binding map-values-binding-vectors)))

(define out-path "snapshot.json")

(call-with-output-file out-path
  (λ (port)
    (write-json snapshot port)
    (newline port))
  #:exists 'replace)

(printf "Wrote ~a (~a bytes)\n" out-path (file-size out-path))
