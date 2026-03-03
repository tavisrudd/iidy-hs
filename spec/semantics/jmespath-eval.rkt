#lang racket/base
;; JMESPath query evaluation semantics
;;
;; Main metafunction: jeval
;;   jeval : jx v → v
;;   "JMESPath expression jx evaluated against value v produces value v"
;;
;; Implements the evaluation rules for iidy's JMESPath subset.
;; No slice expressions, no function calls (built-in functions).
;;
;; Uses JMESPath truthiness (all numbers truthy, including 0).
;; Comparison: == and != work on any values (structural equality);
;; <, <=, >, >= only work on numbers (false otherwise).

(require redex/reduction-semantics
         racket/match
         "../lang/core.rkt"
         "../lang/jmespath.rkt"
         "truthiness.rkt")
(provide jeval jcompare)


;; ═══════════════════════════════════════════════════════════════════
;; jeval: evaluate a JMESPath expression against a value
;; ═══════════════════════════════════════════════════════════════════

(define-metafunction Iidy-JMESPath
  jeval : jx v -> v

  ;; ── Identity: @ ─────────────────────────────────────────────────
  [(jeval jidentity v) v]

  ;; ── Literal ─────────────────────────────────────────────────────
  [(jeval (jlit v) v_ctx) v]

  ;; ── Field access ────────────────────────────────────────────────
  ;; Object: lookup key; anything else: null
  [(jeval (jfield s) (obj ((k_i v_i) ...)))
   ,(let ([result (assoc (term s)
                         (map list (term (k_i ...)) (term (v_i ...))))])
      (if result (cadr result) (term null)))]

  [(jeval (jfield s) v) null]

  ;; ── Array index ─────────────────────────────────────────────────
  ;; Supports negative indices (Python-style: -1 = last).
  [(jeval (jindex i) (arr (v_items ...)))
   ,(let* ([items (term (v_items ...))]
           [len (length items)]
           [idx (term i)]
           [effective (if (< idx 0) (+ len idx) idx)])
      (if (and (>= effective 0) (< effective len))
          (list-ref items effective)
          (term null)))]

  [(jeval (jindex i) v) null]

  ;; ── Sub-expression: a.b ─────────────────────────────────────────
  ;; Evaluate left, then evaluate right against result
  [(jeval (jsub jx_l jx_r) v)
   (jeval jx_r v_l)
   (where v_l (jeval jx_l v))]

  ;; ── Wildcard: * ─────────────────────────────────────────────────
  ;; Object → array of all values; Array → pass through; else null
  [(jeval jwildcard (obj ((k_i v_i) ...)))
   (arr (v_i ...))]

  [(jeval jwildcard (arr (v_items ...)))
   (arr (v_items ...))]

  [(jeval jwildcard v) null]

  ;; ── Projection: source[*].rhs ──────────────────────────────────
  ;; Evaluate source to get an array, then map rhs over each element.
  ;; Non-null results are collected; null results are filtered out.
  [(jeval (jproj jx_src jx_rhs) v)
   (jproj-map jx_rhs (v_items ...))
   (where (arr (v_items ...)) (jeval jx_src v))]

  ;; Source not an array → null
  [(jeval (jproj jx_src jx_rhs) v) null]

  ;; ── Flatten: expr[] ─────────────────────────────────────────────
  ;; Flatten one level: arrays are inlined, non-arrays kept as-is.
  [(jeval (jflatten jx) v)
   (arr ,(apply append
                (map (lambda (item)
                       (match item
                         [`(arr ,elems) elems]
                         [other (list other)]))
                     (term (v_items ...)))))
   (where (arr (v_items ...)) (jeval jx v))]

  [(jeval (jflatten jx) v) null]

  ;; ── Filter: [?cond] ────────────────────────────────────────────
  ;; Evaluate source to array, filter by condition, map projection.
  [(jeval (jfilter jx_cond jx_proj) (arr (v_items ...)))
   (jfilter-map jx_cond jx_proj (v_items ...))]

  [(jeval (jfilter jx_cond jx_proj) v) null]

  ;; ── Multi-select hash: {a: expr, b: expr} ──────────────────────
  [(jeval (jmulti-hash ((s_k jx_v) ...)) v)
   (obj ((s_k v_out) ...))
   (where (v_out ...) ((jeval jx_v v) ...))]

  ;; ── Multi-select list: [expr, expr] ─────────────────────────────
  [(jeval (jmulti-list (jx_items ...)) v)
   (arr ((jeval jx_items v) ...))]

  ;; ── Pipe: a | b ────────────────────────────────────────────────
  ;; Evaluate left, feed result to right
  [(jeval (jpipe jx_l jx_r) v)
   (jeval jx_r (jeval jx_l v))]

  ;; ── Comparison ──────────────────────────────────────────────────
  [(jeval (jcmp cmp-op jx_l jx_r) v)
   (bool (jcompare cmp-op (jeval jx_l v) (jeval jx_r v)))]

  ;; ── Negation: !expr ─────────────────────────────────────────────
  [(jeval (jnot jx) v)
   (bool ,(if (term (truthy/jmespath (jeval jx v))) (term #f) (term #t)))])


;; ═══════════════════════════════════════════════════════════════════
;; jcompare: comparison operator evaluation
;;
;; == and != work on any values (structural equality).
;; <, <=, >, >= only work on numbers; false for non-numbers.
;; ═══════════════════════════════════════════════════════════════════

(define-metafunction Iidy-JMESPath
  jcompare : cmp-op v v -> b

  ;; Equality: structural
  [(jcompare == v_1 v_2) ,(if (equal? (term v_1) (term v_2)) (term #t) (term #f))]
  [(jcompare != v_1 v_2) ,(if (equal? (term v_1) (term v_2)) (term #f) (term #t))]

  ;; Ordering: numbers only
  [(jcompare <  (num n_1) (num n_2)) ,(if (<  (term n_1) (term n_2)) (term #t) (term #f))]
  [(jcompare <= (num n_1) (num n_2)) ,(if (<= (term n_1) (term n_2)) (term #t) (term #f))]
  [(jcompare >  (num n_1) (num n_2)) ,(if (>  (term n_1) (term n_2)) (term #t) (term #f))]
  [(jcompare >= (num n_1) (num n_2)) ,(if (>= (term n_1) (term n_2)) (term #t) (term #f))]

  ;; Ordering on non-numbers: always false
  [(jcompare cmp-op v_1 v_2) #f])


;; ═══════════════════════════════════════════════════════════════════
;; jproj-map: map projection RHS over array, filtering out nulls
;; ═══════════════════════════════════════════════════════════════════

(define-metafunction Iidy-JMESPath
  jproj-map : jx (v ...) -> v

  [(jproj-map jx ())
   (arr ())]

  ;; Result is null: skip
  [(jproj-map jx (v_hd v_rest ...))
   (jproj-map jx (v_rest ...))
   (where null (jeval jx v_hd))]

  ;; Result is non-null: include
  [(jproj-map jx (v_hd v_rest ...))
   (arr (v_result v_rest-results ...))
   (where v_result (jeval jx v_hd))
   (where (arr (v_rest-results ...)) (jproj-map jx (v_rest ...)))])


;; ═══════════════════════════════════════════════════════════════════
;; jfilter-map: filter array by condition, then map identity
;; (filter condition is the first jx, projection is the second)
;; ═══════════════════════════════════════════════════════════════════

(define-metafunction Iidy-JMESPath
  jfilter-map : jx jx (v ...) -> v

  [(jfilter-map jx_cond jx_proj ())
   (arr ())]

  ;; Condition truthy: include (apply projection)
  [(jfilter-map jx_cond jx_proj (v_hd v_rest ...))
   (arr (v_result v_rest-results ...))
   (where v_test (jeval jx_cond v_hd))
   (where #t (truthy/jmespath v_test))
   (where v_result (jeval jx_proj v_hd))
   (where (arr (v_rest-results ...)) (jfilter-map jx_cond jx_proj (v_rest ...)))]

  ;; Condition falsy: skip
  [(jfilter-map jx_cond jx_proj (v_hd v_rest ...))
   (jfilter-map jx_cond jx_proj (v_rest ...))
   (where v_test (jeval jx_cond v_hd))
   (where #f (truthy/jmespath v_test))])
