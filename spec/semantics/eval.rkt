#lang racket/base
;; Big-step evaluation semantics for iidy preprocessing
;;
;; Main judgment: ⟨e, σ⟩ ⇓ v
;;   "expression e in environment σ evaluates to value v"
;;
;; All evaluation is bottom-up (depth-first), eager, and deterministic.
;; New bindings are appended and shadow earlier ones (rightmost wins).
;; Object key ordering is preserved throughout.

(require redex/reduction-semantics
         racket/string
         "../lang/core.rkt"
         "../lang/preprocessing.rkt"
         "truthiness.rkt"
         "env.rkt"
         "merge.rkt")
(provide eval)


;; ═══════════════════════════════════════════════════════════════════
;; Helper metafunction: eval-one
;;
;; Bridges metafunctions → judgment form. Lets metafunctions call
;; the eval judgment via (where v (eval-one e σ)).
;; ═══════════════════════════════════════════════════════════════════

(define-metafunction Iidy-Preprocess
  eval-one : e σ -> v

  [(eval-one e σ) v
   (judgment-holds (eval e σ v))])


;; ═══════════════════════════════════════════════════════════════════
;; Helper metafunctions for iteration
;; ═══════════════════════════════════════════════════════════════════

;; ── let-bind: sequentially evaluate and bind let-bindings ───────
;; Each binding can reference previous bindings.

(define-metafunction Iidy-Preprocess
  let-bind : ((var-name e) ...) σ -> σ

  [(let-bind () σ)
   σ]

  [(let-bind ((var-name_1 e_1) (var-name_rest e_rest) ...) σ)
   (let-bind ((var-name_rest e_rest) ...) σ_ext)
   (where v_1 (eval-one e_1 σ))
   (where σ_ext (extend var-name_1 v_1 σ))])


;; ── map-items: evaluate template for each item ──────────────────

(define-metafunction Iidy-Preprocess
  map-items : (v ...) e var-name σ -> (v ...)

  [(map-items () e var-name σ) ()]

  [(map-items (v_hd v_rest ...) e var-name σ)
   (v_result v_results ...)
   (where σ_ext (extend var-name v_hd σ))
   (where v_result (eval-one e σ_ext))
   (where (v_results ...) (map-items (v_rest ...) e var-name σ))])


;; ── map-filter-items: map with filter ───────────────────────────

(define-metafunction Iidy-Preprocess
  map-filter-items : (v ...) e var-name e σ -> (v ...)

  [(map-filter-items () e_tmpl var-name e_filt σ) ()]

  ;; Filter passes: include result
  [(map-filter-items (v_hd v_rest ...) e_tmpl var-name e_filt σ)
   (v_result v_results ...)
   (where σ_ext (extend var-name v_hd σ))
   (where v_filt (eval-one e_filt σ_ext))
   (where #t (truthy v_filt))
   (where v_result (eval-one e_tmpl σ_ext))
   (where (v_results ...) (map-filter-items (v_rest ...) e_tmpl var-name e_filt σ))]

  ;; Filter fails: skip item
  [(map-filter-items (v_hd v_rest ...) e_tmpl var-name e_filt σ)
   (v_results ...)
   (where σ_ext (extend var-name v_hd σ))
   (where v_filt (eval-one e_filt σ_ext))
   (where #f (truthy v_filt))
   (where (v_results ...) (map-filter-items (v_rest ...) e_tmpl var-name e_filt σ))])


;; ── map-values-items: transform object values ───────────────────
;; Binds var to {key: k, value: v} for each entry.

(define-metafunction Iidy-Preprocess
  map-values-items : ((k v) ...) e var-name σ -> ((k v) ...)

  [(map-values-items () e var-name σ) ()]

  [(map-values-items ((k_hd v_hd) (k_rest v_rest) ...) e var-name σ)
   ((k_hd v_result) (k_out v_out) ...)
   (where v_binding (obj (("key" (str k_hd)) ("value" v_hd))))
   (where σ_ext (extend var-name v_binding σ))
   (where v_result (eval-one e σ_ext))
   (where ((k_out v_out) ...) (map-values-items ((k_rest v_rest) ...) e var-name σ))])


;; ── group-by-items: group array items by computed key ────────────

(define-metafunction Iidy-Preprocess
  group-by-items : (v ...) e var-name σ -> ((string (v ...)) ...)

  [(group-by-items () e_key var-name σ) ()]

  [(group-by-items (v_hd v_rest ...) e_key var-name σ)
   ,(let* ([vn (term var-name)]
           [σ-ext (term (extend ,vn v_hd σ))]
           [key-val (term (eval-one e_key ,σ-ext))]
           [key-str (term (val->text ,key-val))]
           [rest-groups (term (group-by-items (v_rest ...) e_key var-name σ))])
      ;; Insert v_hd into group for key-str, preserving input order.
      ;; Since we recurse on rest first, rest-groups has later items.
      ;; cons v_hd onto existing group items maintains L-to-R element order.
      ;; New groups are appended to preserve first-seen key order.
      (let ([existing (assoc key-str rest-groups)])
        (if existing
            (map (lambda (pair)
                   (if (equal? (car pair) key-str)
                       (list key-str (cons (term v_hd) (cadr pair)))
                       pair))
                 rest-groups)
            ;; New group: append to end for first-seen key ordering
            (append rest-groups (list (list key-str (list (term v_hd))))))))])


;; ── group-by-to-obj: convert grouped pairs to obj value ─────────

(define-metafunction Iidy-Preprocess
  group-by-to-obj : ((string (v ...)) ...) -> v

  [(group-by-to-obj ())
   (obj ())]

  [(group-by-to-obj ((string_k (v_items ...)) (string_rest (v_rest_items ...)) ...))
   (obj ((string_k (arr (v_items ...))) (k_out v_out) ...))
   (where (obj ((k_out v_out) ...))
          (group-by-to-obj ((string_rest (v_rest_items ...)) ...)))])


;; ═══════════════════════════════════════════════════════════════════
;; eval : e σ → v
;;
;; Big-step evaluation judgment. Each rule corresponds to one
;; preprocessing tag form or structural node.
;; ═══════════════════════════════════════════════════════════════════

(define-judgment-form Iidy-Preprocess
  #:mode (eval I I O)
  #:contract (eval e σ v)


  ;; ── Literal values ────────────────────────────────────────────
  ;; Values evaluate to themselves.

  [--- "E-Null"
   (eval null σ null)]

  [--- "E-Bool"
   (eval (bool b) σ (bool b))]

  [--- "E-Num"
   (eval (num n) σ (num n))]

  [--- "E-Str"
   (eval (str s) σ (str s))]

  [--- "E-Arr"
   (eval (arr (v ...)) σ (arr (v ...)))]

  [--- "E-Obj"
   (eval (obj ((k v) ...)) σ (obj ((k v) ...)))]


  ;; ── Sequence evaluation ───────────────────────────────────────

  [(eval e_i σ v_i) ...
   --- "E-Seq"
   (eval (seq (e_i ...)) σ (arr (v_i ...)))]


  ;; ── Object evaluation ─────────────────────────────────────────

  [(eval e_i σ v_i) ...
   --- "E-Obj-E"
   (eval (obj-e ((ke_i e_i) ...)) σ (obj ((ke_i v_i) ...)))]


  ;; ── Variable lookup (!$) ──────────────────────────────────────

  [(where v (resolve-path (string_seg ...) σ))
   (side-condition (not (equal? (term v) (term unbound))))
   --- "E-Var"
   (eval (var (string_seg ...)) σ v)]


  ;; ── Conditional (!$if) ────────────────────────────────────────

  [(eval e_test σ v_test)
   (where #t (truthy v_test))
   (eval e_then σ v)
   --- "E-IfTrue"
   (eval (if e_test e_then e_else) σ v)]

  [(eval e_test σ v_test)
   (where #f (truthy v_test))
   (eval e_else σ v)
   --- "E-IfFalse"
   (eval (if e_test e_then e_else) σ v)]


  ;; ── Let binding (!$let) ───────────────────────────────────────

  [(where σ_ext (let-bind ((var-name_i e_i) ...) σ))
   (eval e_body σ_ext v)
   --- "E-Let"
   (eval (let ((var-name_i e_i) ...) e_body) σ v)]


  ;; ── Equality (!$eq) ───────────────────────────────────────────

  [(eval e_1 σ v_1)
   (eval e_2 σ v_2)
   (where b ,(if (equal? (term v_1) (term v_2)) (term #t) (term #f)))
   --- "E-Eq"
   (eval (eq e_1 e_2) σ (bool b))]


  ;; ── Negation (!$not) ──────────────────────────────────────────

  [(eval e σ v_inner)
   (where b_t (truthy v_inner))
   (where b ,(if (term b_t) (term #f) (term #t)))
   --- "E-Not"
   (eval (not e) σ (bool b))]


  ;; ── Split (!$split) ───────────────────────────────────────────

  [(eval e_delim σ (str s_delim))
   (eval e_str σ (str s_str))
   (where (v_parts ...) ,(map (lambda (p) (term (str ,p)))
                               (regexp-split (regexp-quote (term s_delim))
                                             (term s_str))))
   --- "E-Split"
   (eval (split e_delim e_str) σ (arr (v_parts ...)))]


  ;; ── Join (!$join) ─────────────────────────────────────────────

  [(eval e_delim σ (str s_delim))
   (eval e_arr σ (arr (v_items ...)))
   (where (string_texts ...) ((val->text v_items) ...))
   (where s_result ,(string-join (term (string_texts ...)) (term s_delim)))
   --- "E-Join"
   (eval (join e_delim e_arr) σ (str s_result))]


  ;; ── Map (!$map) ───────────────────────────────────────────────

  [(eval e_items σ (arr (v_items ...)))
   (where (v_results ...) (map-items (v_items ...) e_tmpl var-name σ))
   --- "E-Map"
   (eval (map e_items e_tmpl var-name) σ (arr (v_results ...)))]


  ;; ── Map with filter (!$map-f) ─────────────────────────────────

  [(eval e_items σ (arr (v_items ...)))
   (where (v_results ...)
          (map-filter-items (v_items ...) e_tmpl var-name e_filter σ))
   --- "E-MapF"
   (eval (map-f e_items e_tmpl var-name e_filter) σ (arr (v_results ...)))]


  ;; ── Concat (!$concat) ─────────────────────────────────────────

  [(eval e_i σ v_i) ...
   (where v_result (concat-arrs (v_i ...)))
   --- "E-Concat"
   (eval (concat (e_i ...)) σ v_result)]


  ;; ── Merge (!$merge) ───────────────────────────────────────────

  [(eval e_i σ v_i) ...
   (where v_result (merge-all (v_i ...)))
   --- "E-Merge"
   (eval (merge (e_i ...)) σ v_result)]


  ;; ── ConcatMap (!$concatMap) ───────────────────────────────────

  [(eval e_items σ (arr (v_items ...)))
   (where (v_mapped ...) (map-items (v_items ...) e_tmpl var-name σ))
   (where v_result (concat-arrs (v_mapped ...)))
   --- "E-ConcatMap"
   (eval (concat-map e_items e_tmpl var-name) σ v_result)]

  [(eval e_items σ (arr (v_items ...)))
   (where (v_mapped ...)
          (map-filter-items (v_items ...) e_tmpl var-name e_filter σ))
   (where v_result (concat-arrs (v_mapped ...)))
   --- "E-ConcatMapF"
   (eval (concat-map-f e_items e_tmpl var-name e_filter) σ v_result)]


  ;; ── MergeMap (!$mergeMap) ─────────────────────────────────────

  [(eval e_items σ (arr (v_items ...)))
   (where (v_mapped ...) (map-items (v_items ...) e_tmpl var-name σ))
   (where v_result (merge-all (v_mapped ...)))
   --- "E-MergeMap"
   (eval (merge-map e_items e_tmpl var-name) σ v_result)]


  ;; ── FromPairs (!$fromPairs) ───────────────────────────────────

  [(eval e σ v_pairs)
   (where v_result (obj-from-pairs v_pairs))
   --- "E-FromPairs"
   (eval (from-pairs e) σ v_result)]


  ;; ── MapListToHash (!$mapListToHash) ───────────────────────────

  [(eval e_items σ (arr (v_items ...)))
   (where (v_mapped ...) (map-items (v_items ...) e_tmpl var-name σ))
   (where v_result (obj-from-pairs (arr (v_mapped ...))))
   --- "E-MapListToHash"
   (eval (map-list-to-hash e_items e_tmpl var-name) σ v_result)]

  [(eval e_items σ (arr (v_items ...)))
   (where (v_mapped ...)
          (map-filter-items (v_items ...) e_tmpl var-name e_filter σ))
   (where v_result (obj-from-pairs (arr (v_mapped ...))))
   --- "E-MapListToHashF"
   (eval (map-list-to-hash-f e_items e_tmpl var-name e_filter) σ v_result)]


  ;; ── MapValues (!$mapValues) ───────────────────────────────────

  [(eval e_items σ (obj ((k_i v_i) ...)))
   (where ((k_out v_out) ...)
          (map-values-items ((k_i v_i) ...) e_tmpl var-name σ))
   --- "E-MapValues"
   (eval (map-values e_items e_tmpl var-name) σ (obj ((k_out v_out) ...)))]


  ;; ── GroupBy (!$groupBy) ───────────────────────────────────────

  [(eval e_items σ (arr (v_items ...)))
   (where ((string_k (v_grouped ...)) ...)
          (group-by-items (v_items ...) e_key var-name σ))
   (where v_result (group-by-to-obj ((string_k (v_grouped ...)) ...)))
   --- "E-GroupBy"
   (eval (group-by e_items e_key var-name) σ v_result)]


  ;; ── Escape (!$escape) ─────────────────────────────────────────
  ;; Suppresses tag resolution: converts the AST to a raw value
  ;; WITHOUT evaluating preprocessing tags. In the formal model,
  ;; literals pass through unchanged (escape is identity on values).
  ;; For non-value expressions, escape converts to a string sentinel.
  ;; (The full raw-conversion semantics depend on YAML AST structure
  ;; which is outside this formal model's scope.)

  [--- "E-Escape-Val"
   (eval (escape v) σ v)]


  ;; ── CloudFormation pass-through ───────────────────────────────

  [(eval e σ v)
   --- "E-Cfn"
   (eval (cfn tag-name_t e) σ (obj ((tag-name_t v))))]

  )
