#lang racket/base
;; Environment operations for iidy preprocessing
;;
;; Environments are ordered association lists with string keys.
;; Later entries shadow earlier ones (lookup searches right-to-left).
;;
;; Variable paths use dot-notation: "a.b.c" traverses nested objects.
;; Bracket notation [varName] is expanded before path resolution.

(require redex/reduction-semantics
         racket/list
         "../lang/core.rkt")
(provide lookup extend extend-many
         resolve-path traverse-path
         env-keys)


;; ── lookup: find a variable in the environment ──────────────────
;; Searches right-to-left (most recent binding wins).
;; Returns the value or the sentinel `unbound`.
;; Uses simple recursive scan for clarity.

(define-metafunction Iidy-Core
  lookup : string σ -> any

  ;; Empty env: not found
  [(lookup string_key ())
   unbound]

  ;; Head matches: but check if a later binding shadows this one
  [(lookup string_key ((string_key v_found) (string_rest v_rest) ...))
   (lookup-or string_key v_found ((string_rest v_rest) ...))]

  ;; Head doesn't match: recurse
  [(lookup string_key ((string_other v_other) (string_rest v_rest) ...))
   (lookup string_key ((string_rest v_rest) ...))])


;; Helper: if key appears later, use that; otherwise use current value
(define-metafunction Iidy-Core
  lookup-or : string v σ -> any

  [(lookup-or string_key v_default ())
   v_default]

  [(lookup-or string_key v_default ((string_key v_newer) (string_rest v_rest) ...))
   (lookup-or string_key v_newer ((string_rest v_rest) ...))]

  [(lookup-or string_key v_default ((string_other v_other) (string_rest v_rest) ...))
   (lookup-or string_key v_default ((string_rest v_rest) ...))])


;; ── extend: add a single binding ────────────────────────────────
;; Appends to the right so it shadows any existing binding.

(define-metafunction Iidy-Core
  extend : string v σ -> σ

  [(extend string_key v ((string_i v_i) ...))
   ((string_i v_i) ... (string_key v))])


;; ── extend-many: add multiple bindings at once ──────────────────
;; Each new binding appended in order.

(define-metafunction Iidy-Core
  extend-many : ((string v) ...) σ -> σ

  [(extend-many () σ)
   σ]

  [(extend-many ((string_1 v_1) (string_rest v_rest) ...) σ)
   (extend-many ((string_rest v_rest) ...) (extend string_1 v_1 σ))])


;; ── resolve-path: look up a dot-separated variable path ─────────
;; path = (segment ...) where each segment is a string.
;; First segment is the root variable name; rest traverse into the value.

(define-metafunction Iidy-Core
  resolve-path : (string ...) σ -> any

  ;; Empty path: error
  [(resolve-path () σ)
   unbound]

  ;; Single segment: direct lookup
  [(resolve-path (string_root) σ)
   (lookup string_root σ)]

  ;; Multi-segment: lookup root then traverse
  [(resolve-path (string_root string_rest ...) σ)
   (traverse-path (string_rest ...) (lookup string_root σ))])


;; ── traverse-path: navigate into a value via segments ───────────
;; Handles object field access and array index access.

(define-metafunction Iidy-Core
  traverse-path : (string ...) any -> any

  ;; Base case: no more segments
  [(traverse-path () v)
   v]

  ;; Can't traverse into unbound
  [(traverse-path (string_seg string_rest ...) unbound)
   unbound]

  ;; Object field access
  [(traverse-path (string_seg string_rest ...) (obj ((k_i v_i) ...)))
   (traverse-path (string_rest ...) (obj-lookup string_seg ((k_i v_i) ...)))]

  ;; Array integer index (non-negative only at this level)
  [(traverse-path (string_seg string_rest ...) (arr (v_i ...)))
   (traverse-path (string_rest ...) (arr-index string_seg (v_i ...)))]

  ;; Any other value: can't traverse further
  [(traverse-path (string_seg string_rest ...) v)
   unbound])


;; ── obj-lookup: find a key in an ordered object ─────────────────
;; Returns the FIRST match (objects should not have duplicate keys).
;; This differs from env lookup which returns the LAST match
;; (rightmost binding wins for shadowing).

(define-metafunction Iidy-Core
  obj-lookup : string ((k v) ...) -> any

  [(obj-lookup string_k ())
   unbound]

  [(obj-lookup string_k ((string_k v_found) (k_rest v_rest) ...))
   v_found]

  [(obj-lookup string_k ((string_other v_other) (k_rest v_rest) ...))
   (obj-lookup string_k ((k_rest v_rest) ...))])


;; ── arr-index: access array by string index ─────────────────────
;; Parses string as non-negative integer, returns element or unbound.

(define-metafunction Iidy-Core
  arr-index : string (v ...) -> any

  [(arr-index string_idx (v_items ...))
   ,(let ([idx (string->number (term string_idx))])
      (if (and idx (exact-integer? idx) (>= idx 0) (< idx (length (term (v_items ...)))))
          (list-ref (term (v_items ...)) idx)
          (term unbound)))])


;; ── env-keys: list all variable names ───────────────────────────
;; Used for error messages ("available variables: ...").

(define-metafunction Iidy-Core
  env-keys : σ -> (string ...)

  [(env-keys ())
   ()]

  [(env-keys ((string_1 v_1) (string_rest v_rest) ...))
   ,(remove-duplicates (term (string_1 string_rest ...)))])
