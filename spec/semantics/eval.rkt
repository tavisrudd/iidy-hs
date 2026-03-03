#lang racket/base
;; Big-step evaluation semantics for iidy preprocessing
;;
;; Main judgment: ⟨e, σ⟩ ⇓ v
;;   "expression e in environment σ evaluates to value v"
;;
;; All evaluation is bottom-up (depth-first), eager, and deterministic.
;; New bindings are appended and shadow earlier ones (rightmost wins).
;; Object key ordering is preserved throughout.
;;
;; ── Compositional limitation ──────────────────────────────────────
;; The sub-languages (Handlebars, JMESPath, bracket expansion) each
;; extend Iidy-Core independently and are fully specified + tested in
;; their own modules. However, they cannot compose within this eval
;; judgment because their non-terminals are not in Iidy-Preprocess's
;; scope. Concretely:
;;
;;   - E-Tpl uses simple regex rendering (simple-tpl-render), not the
;;     full Handlebars renderer (handlebars-eval.rkt). Block helpers,
;;     helper functions, and literals are not available here.
;;   - E-Var-J (JMESPath query) is specified as a comment only — the
;;     jx non-terminals from jmespath.rkt are not in scope.
;;   - Bracket expansion (bracket-expansion.rkt) is tested in
;;     isolation, not composed with variable resolution.
;;
;; A union language (Iidy-Full) merging all sub-language grammars
;; would resolve this, allowing E-Tpl to call render-template and
;; E-Var-J to call jeval. This was deferred as the sub-languages are
;; individually validated (210 tests) and the refactor is substantial.
;; ──────────────────────────────────────────────────────────────────

(require redex/reduction-semantics
         racket/string
         racket/match
         "../lang/core.rkt"
         "../lang/preprocessing.rkt"
         "truthiness.rkt"
         "env.rkt"
         "merge.rkt")
(provide eval env-to-obj dot-query val->json escape-to-raw)


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


;; ── insert-into-group: insert a value into grouped pairs ────────
;; Finds the group matching string_k and prepends v_new to it.
;; If no matching group exists, appends a new group at the end
;; (preserving first-seen key ordering).

(define-metafunction Iidy-Preprocess
  insert-into-group : string v ((string (v ...)) ...) -> ((string (v ...)) ...)

  ;; No groups yet: create new group with this value
  [(insert-into-group string_k v_new ())
   ((string_k (v_new)))]

  ;; Found matching key: prepend value to that group's items
  [(insert-into-group string_k v_new
                      ((string_k (v_existing ...))
                       (string_rest (v_rest ...)) ...))
   ((string_k (v_new v_existing ...))
    (string_rest (v_rest ...)) ...)]

  ;; Key doesn't match first group: keep it, recurse on rest
  [(insert-into-group string_k v_new
                      ((string_first (v_first ...))
                       (string_rest (v_rest ...)) ...))
   ((string_first (v_first ...))
    (string_out (v_out ...)) ...)
   (where ((string_out (v_out ...)) ...)
          (insert-into-group string_k v_new
                             ((string_rest (v_rest ...)) ...)))])


;; ── group-by-items: group array items by computed key ────────────
;; Recursively processes items right-to-left, inserting each into
;; the appropriate group. Left-to-right element order is preserved
;; because we recurse on rest first, then prepend the current item.

(define-metafunction Iidy-Preprocess
  group-by-items : (v ...) e var-name σ -> ((string (v ...)) ...)

  [(group-by-items () e_key var-name σ) ()]

  [(group-by-items (v_hd v_rest ...) e_key var-name σ)
   (insert-into-group string_k v_hd ((string_g (v_g ...)) ...))
   (where σ_ext (extend var-name v_hd σ))
   (where v_key (eval-one e_key σ_ext))
   (where string_k (val->text v_key))
   (where ((string_g (v_g ...)) ...)
          (group-by-items (v_rest ...) e_key var-name σ))])


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
;; Escape helper: convert AST to raw value without evaluation
;;
;; Models Haskell's astToValueRaw function. Structural nodes (seq,
;; obj-e) are recursively converted. Template strings become literal
;; strings (not interpolated). Preprocessing tag expressions become
;; the sentinel string "!$escaped". CloudFormation tags are preserved
;; as objects with their tag name as key.
;; ═══════════════════════════════════════════════════════════════════

(define-metafunction Iidy-Preprocess
  escape-to-raw : e -> v

  ;; Values pass through unchanged
  [(escape-to-raw v) v]

  ;; Sequence: recursively escape each element
  [(escape-to-raw (seq (e_i ...)))
   (arr ((escape-to-raw e_i) ...))]

  ;; Object expression: recursively escape each value
  [(escape-to-raw (obj-e ((ke_i e_i) ...)))
   (obj ((ke_i (escape-to-raw e_i)) ...))]

  ;; Template string: return as literal (NOT interpolated)
  [(escape-to-raw (tpl s)) (str s)]

  ;; CloudFormation: preserve as object with tag name key
  [(escape-to-raw (cfn tag-name_t e))
   (obj ((tag-name_t (escape-to-raw e))))]

  ;; All preprocessing tag expressions → sentinel string
  ;; This matches the Haskell implementation's astToValueRaw behavior
  ;; where any !$ tag inside !$escape becomes (str "!$escaped").
  [(escape-to-raw e) (str "!$escaped")])


;; ═══════════════════════════════════════════════════════════════════
;; Integration helpers for sub-language rules
;; ═══════════════════════════════════════════════════════════════════

;; ── env-to-obj: convert environment to object value ───────────
;; Bridges σ (env) → v (obj) for Handlebars template context.
;; The Handlebars renderer takes a value (typically obj) as context,
;; not an environment. This converts the environment to an obj.

(define-metafunction Iidy-Preprocess
  env-to-obj : σ -> v

  [(env-to-obj ((string_k v_v) ...))
   (obj ((string_k v_v) ...))])


;; ── dot-query: apply dot-query to a value ─────────────────────
;; Two modes (determined by whether query contains commas):
;;   Comma-separated: "a, b" → {a: val.a, b: val.b}
;;   Single path:     "x.y"  → traverse dot path into value

(define-metafunction Iidy-Preprocess
  dot-query : string v -> any

  [(dot-query string_q v_base)
   ,(let* ([q (term string_q)]
           [base (term v_base)]
           [parts (map string-trim (string-split q ","))])
      (if (= (length parts) 1)
          ;; Single path: split on dots, traverse into value
          (let ([segs (string-split (car parts) ".")])
            (term (traverse-path ,segs ,base)))
          ;; Multiple keys: select from object
          (match base
            [`(obj ,kvs)
             (let ([selected (map (lambda (key)
                                   (let ([found (assoc key kvs)])
                                     (list key (if found (cadr found) (term null)))))
                                 parts)])
               `(obj ,selected))]
            [_ (term null)])))])


;; ── simple-tpl-render: basic {{path}} template substitution ───
;; Implements simple variable interpolation: {{path.to.var}}.
;; The full Handlebars semantics (block helpers, helpers, context
;; merging) are specified in semantics/handlebars-eval.rkt.

(define (simple-tpl-render template-str env-term)
  (regexp-replace* #rx"\\{\\{([^{}]+)\\}\\}"
    template-str
    (lambda (full-match captured)
      (let* ([path-str (string-trim captured)]
             [segments (string-split path-str ".")]
             [resolved (term (resolve-path ,segments ,env-term))])
        (if (equal? resolved (term unbound))
            ""
            (term (val->text ,resolved)))))))


;; ── val->json: convert value to JSON string ───────────────────
;; Simplified JSON serialization for the formal model.
;; String escaping is minimal (sufficient for specification).

(define (val->json v)
  (match v
    ['null "null"]
    [`(bool #t) "true"]
    [`(bool #f) "false"]
    [`(num ,n) (number->string n)]
    ;; NOTE: String escaping is simplified for the formal model.
    ;; Strings containing ", \, or control characters would produce
    ;; invalid JSON. The Haskell implementation uses Aeson for correct escaping.
    [`(str ,s) (string-append "\"" s "\"")]
    [`(arr (,items ...))
     (string-append "[" (string-join (map val->json items) ",") "]")]
    [`(obj ((,ks ,vs) ...))
     (string-append "{"
       (string-join (map (lambda (k v)
                           (string-append "\"" k "\":" (val->json v)))
                         ks vs)
                    ",")
       "}")]
    [_ "null"]))


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
  ;; WITHOUT evaluating preprocessing tags.
  ;;
  ;; Models the Haskell astToValueRaw function:
  ;;   - Values pass through unchanged
  ;;   - Structural expressions (seq, obj-e) are recursively escaped
  ;;   - Template strings become literal (not interpolated)
  ;;   - Preprocessing tags become (str "!$escaped")
  ;;   - CloudFormation tags become objects with tag name key
  ;;
  ;; Uses the escape-to-raw metafunction (defined above).

  [(where v (escape-to-raw e))
   --- "E-Escape"
   (eval (escape e) σ v)]


  ;; ── CloudFormation pass-through ───────────────────────────────

  [(eval e σ v)
   --- "E-Cfn"
   (eval (cfn tag-name_t e) σ (obj ((tag-name_t v))))]


  ;; ── Template string (!$tpl) ───────────────────────────────────
  ;; In iidy, any YAML string containing {{...}} is a templated string.
  ;; The full Handlebars rendering semantics (block helpers, helpers,
  ;; context merging) are specified in semantics/handlebars-eval.rkt.
  ;;
  ;; This rule implements simple {{path.to.var}} substitution.
  ;; The variable context is the evaluation environment σ.

  [(where s_out ,(simple-tpl-render (term s) (term σ)))
   --- "E-Tpl"
   (eval (tpl s) σ (str s_out))]


  ;; ── Variable with dot-query (!$ path ? query) ─────────────────
  ;; Resolves the base variable, then applies the dot-query.
  ;; Comma-separated: "a, b" → select keys → new object
  ;; Single path:     "x.y"  → traverse → nested value

  [(where v_base (resolve-path (string_seg ...) σ))
   (side-condition (not (equal? (term v_base) (term unbound))))
   (where v_result (dot-query query v_base))
   (side-condition (not (equal? (term v_result) (term unbound))))
   --- "E-Var-Q"
   (eval (var-q (string_seg ...) query) σ v_result)]


  ;; ── Variable with JMESPath (!$ path @ jmespath) ───────────────
  ;; JMESPath query is applied to the resolved base value.
  ;;
  ;; Formal specification:
  ;;   resolve-path(path, σ) = v_base  ≠ unbound
  ;;   parse-jmespath(jmespath) = jx
  ;;   jeval(jx, v_base) = v_result
  ;;   ──────────────────────────────────────────────
  ;;   eval(var-j(path, jmespath), σ) = v_result
  ;;
  ;; The JMESPath evaluation semantics are fully specified and tested
  ;; in semantics/jmespath-eval.rkt (all 14 expression forms).
  ;; This rule requires a JMESPath string parser (outside this model).
  ;;
  ;; [Rule not executable — requires JMESPath string parser.
  ;;  JMESPath evaluation tested via jmespath-tests.rkt.]


  ;; ── Serialization (!$toYamlString) ────────────────────────────
  ;; Converts a value to its YAML text representation.
  ;; In the formal model, uses val->text for simplicity.

  [(eval e σ v)
   (where s_out (val->text v))
   --- "E-ToYaml"
   (eval (to-yaml e) σ (str s_out))]


  ;; ── Serialization (!$toJsonString) ────────────────────────────
  ;; Converts a value to its JSON text representation.

  [(eval e σ v)
   (where s_out ,(val->json (term v)))
   --- "E-ToJson"
   (eval (to-json e) σ (str s_out))]


  ;; ── Deserialization (!$parseYaml, !$parseJson) ────────────────
  ;; Inverse operations of serialization.
  ;; Key property: parse-yaml(to-yaml(v)) = v
  ;;               parse-json(to-json(v)) = v
  ;;
  ;; Full parsing requires YAML/JSON parsers outside this model.
  ;;
  ;; [Rules not executable — require string parsers.
  ;;  Specified by the round-trip property above.]


  ;; ── Template expansion (!$expand) ─────────────────────────────
  ;; Looks up a custom template definition by name, merges default
  ;; and provided parameters, evaluates the template body.
  ;;
  ;; Formal specification (requires template registry Σ):
  ;;   eval(e_name, σ) = (str template-name)
  ;;   eval(e_params, σ) = (obj params)
  ;;   Σ(template-name) = (body, default-params)
  ;;   σ_ext = extend-many(merge(default-params, params), σ)
  ;;   eval(parse(body), σ_ext) = v_result
  ;;   ──────────────────────────────────────────────
  ;;   eval(expand(e_name, e_params), σ, Σ) = v_result
  ;;
  ;; The template registry Σ is not in the eval judgment signature.
  ;; A full implementation would thread Σ through all rules.
  ;;
  ;; [Rule not executable — requires template registry Σ.]

  )
