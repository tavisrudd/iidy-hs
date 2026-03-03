#lang racket/base
;; Handlebars template rendering semantics
;;
;; Main metafunction: render-template
;;   render-template : tmpl v → s
;;   "template tmpl in context v renders to string s"
;;
;; Context is an Iidy-Core value (typically obj). Path lookups
;; traverse the context object. Block helpers may change context.
;;
;; Uses Handlebars truthiness (all numbers truthy, including 0).

(require redex/reduction-semantics
         racket/string
         racket/match
         "../lang/core.rkt"
         "../lang/handlebars.rkt"
         "truthiness.rkt"
         "merge.rkt")
(provide render-template hb-eval hb-lookup hb-val->text)


;; ═══════════════════════════════════════════════════════════════════
;; hb-lookup: traverse a dot-path in a value context
;;
;; Handles object field access and array integer indexing,
;; matching the Haskell lookupPath function.
;; ═══════════════════════════════════════════════════════════════════

(define-metafunction Iidy-Handlebars
  hb-lookup : (s ...) v -> v

  ;; Base case: no more segments
  [(hb-lookup () v) v]

  ;; Object field access
  [(hb-lookup (s_hd s_rest ...) (obj ((k v_val) ...)))
   (hb-lookup (s_rest ...) v_found)
   (where v_found
          ,(let ([result (assoc (term s_hd)
                                (map list (term (k ...)) (term (v_val ...))))])
             (if result (cadr result) (term null))))]

  ;; Array integer index
  [(hb-lookup (s_hd s_rest ...) (arr (v_items ...)))
   (hb-lookup (s_rest ...) v_found)
   (where v_found
          ,(let ([idx (string->number (term s_hd))])
             (if (and idx (exact-integer? idx) (>= idx 0)
                      (< idx (length (term (v_items ...)))))
                 (list-ref (term (v_items ...)) idx)
                 (term null))))]

  ;; Can't traverse into non-container: return null
  [(hb-lookup (s_hd s_rest ...) v) null])


;; ═══════════════════════════════════════════════════════════════════
;; hb-val->text: convert a value to its string representation
;;
;; For template output ({{expr}}). Matches Haskell valueToString.
;; ═══════════════════════════════════════════════════════════════════

(define-metafunction Iidy-Handlebars
  hb-val->text : v -> s

  [(hb-val->text (str s))    s]
  [(hb-val->text (bool #t))  "true"]
  [(hb-val->text (bool #f))  "false"]
  [(hb-val->text null)       ""]
  [(hb-val->text (num n))    ,(number->string (term n))]
  [(hb-val->text (arr any))  ,(format "~a" (term (arr any)))]
  [(hb-val->text (obj any))  ,(format "~a" (term (obj any)))])


;; ═══════════════════════════════════════════════════════════════════
;; hb-eval: evaluate a Handlebars expression against a context value
;; ═══════════════════════════════════════════════════════════════════

(define-metafunction Iidy-Handlebars
  hb-eval : hx v -> v

  ;; Path expression: traverse context
  [(hb-eval (hb-path (s_segs ...)) v_ctx)
   (hb-lookup (s_segs ...) v_ctx)]

  ;; Literals
  [(hb-eval (hb-lit-str s) v_ctx)  (str s)]
  [(hb-eval (hb-lit-num n) v_ctx)  (num n)]
  [(hb-eval (hb-lit-bool b) v_ctx) (bool b)]

  ;; Helper calls — dispatched to hb-call-helper
  [(hb-eval (hb-helper s_name (hx_args ...)) v_ctx)
   (hb-call-helper s_name ((hb-eval hx_args v_ctx) ...) v_ctx)])


;; ═══════════════════════════════════════════════════════════════════
;; hb-call-helper: dispatch helper function calls
;;
;; Models a representative subset of iidy's Handlebars helpers.
;; The full set includes 25+ helpers; we model the structurally
;; interesting ones. Others follow the same pattern.
;; ═══════════════════════════════════════════════════════════════════

(define-metafunction Iidy-Handlebars
  hb-call-helper : s (v ...) v -> v

  ;; lookup: object field access by name
  [(hb-call-helper "lookup" ((obj ((k_i v_i) ...)) (str s_key)) v_ctx)
   ,(let ([result (assoc (term s_key)
                         (map list (term (k_i ...)) (term (v_i ...))))])
      (if result (cadr result) (term null)))]

  ;; eq: structural equality
  [(hb-call-helper "eq" (v_1 v_2) v_ctx)
   (bool ,(if (equal? (term v_1) (term v_2)) (term #t) (term #f)))]

  ;; toLowerCase / toUpperCase — string case transforms
  [(hb-call-helper "toLowerCase" ((str s)) v_ctx)
   (str ,(string-downcase (term s)))]

  [(hb-call-helper "toUpperCase" ((str s)) v_ctx)
   (str ,(string-upcase (term s)))]

  ;; length — collection/string length
  [(hb-call-helper "length" ((arr (v_items ...))) v_ctx)
   (num ,(length (term (v_items ...))))]

  [(hb-call-helper "length" ((str s)) v_ctx)
   (num ,(string-length (term s)))]

  [(hb-call-helper "length" ((obj ((k_i v_i) ...))) v_ctx)
   (num ,(length (term (k_i ...))))]

  ;; concat — string concatenation
  [(hb-call-helper "concat" (v_args ...) v_ctx)
   (str ,(string-join (map (lambda (v) (term (hb-val->text ,v)))
                           (term (v_args ...)))
                      ""))]

  ;; Unknown helper: return null (strict mode would error)
  [(hb-call-helper s_name (v_args ...) v_ctx)
   null])


;; ═══════════════════════════════════════════════════════════════════
;; merge-context: overlay new context on parent for {{#with}}
;; New object keys win; missing keys fall back to parent.
;; ═══════════════════════════════════════════════════════════════════

(define-metafunction Iidy-Handlebars
  merge-context : v v -> v

  ;; Both objects: merge (new overlays parent)
  [(merge-context (obj ((k_p v_p) ...)) (obj ((k_n v_n) ...)))
   (merge-objs (obj ((k_p v_p) ...)) (obj ((k_n v_n) ...)))]

  ;; New context isn't an object: use it directly
  [(merge-context v_parent v_new) v_new])


;; ═══════════════════════════════════════════════════════════════════
;; render-template: render a parsed template against a context
;; ═══════════════════════════════════════════════════════════════════

(define-metafunction Iidy-Handlebars
  render-template : tmpl v -> s

  [(render-template () v_ctx) ""]

  [(render-template (tp_hd tp_rest ...) v_ctx)
   ,(string-append (term s_hd) (term s_rest))
   (where s_hd (render-part tp_hd v_ctx))
   (where s_rest (render-template (tp_rest ...) v_ctx))])


;; ═══════════════════════════════════════════════════════════════════
;; render-part: render a single template part
;; ═══════════════════════════════════════════════════════════════════

(define-metafunction Iidy-Handlebars
  render-part : tp v -> s

  ;; Literal text: pass through
  [(render-part (hb-literal s) v_ctx) s]

  ;; Comment: empty string
  [(render-part hb-comment v_ctx) ""]

  ;; Output: evaluate expression, convert to text
  [(render-part (hb-output hx) v_ctx)
   (hb-val->text (hb-eval hx v_ctx))]

  ;; Block: delegate to render-block
  [(render-part (hb-block block-kind hx tmpl_body tmpl_else) v_ctx)
   (render-block block-kind hx tmpl_body tmpl_else v_ctx)])


;; ═══════════════════════════════════════════════════════════════════
;; render-block: render a block helper
;; ═══════════════════════════════════════════════════════════════════

(define-metafunction Iidy-Handlebars
  render-block : block-kind hx tmpl tmpl v -> s

  ;; ── {{#if expr}}body{{else}}alt{{/if}} ──────────────────────────
  [(render-block "if" hx tmpl_body tmpl_else v_ctx)
   (render-template tmpl_body v_ctx)
   (where v_test (hb-eval hx v_ctx))
   (where #t (truthy/hbs v_test))]

  [(render-block "if" hx tmpl_body tmpl_else v_ctx)
   (render-template tmpl_else v_ctx)
   (where v_test (hb-eval hx v_ctx))
   (where #f (truthy/hbs v_test))]

  ;; ── {{#unless expr}}body{{else}}alt{{/unless}} ──────────────────
  [(render-block "unless" hx tmpl_body tmpl_else v_ctx)
   (render-template tmpl_body v_ctx)
   (where v_test (hb-eval hx v_ctx))
   (where #f (truthy/hbs v_test))]

  [(render-block "unless" hx tmpl_body tmpl_else v_ctx)
   (render-template tmpl_else v_ctx)
   (where v_test (hb-eval hx v_ctx))
   (where #t (truthy/hbs v_test))]

  ;; ── {{#each arr}}body{{else}}empty{{/each}} ─────────────────────
  ;; Array iteration: binds `this` to each element, plus @index, @first, @last
  [(render-block "each" hx tmpl_body tmpl_else v_ctx)
   (render-each-arr (v_items ...) tmpl_body v_ctx 0 ,(sub1 (length (term (v_items ...)))))
   (where (arr (v_items ...)) (hb-eval hx v_ctx))
   (side-condition (> (length (term (v_items ...))) 0))]

  ;; Object iteration: binds `this` to each value, @key to each key
  [(render-block "each" hx tmpl_body tmpl_else v_ctx)
   (render-each-obj ((k_i v_i) ...) tmpl_body v_ctx)
   (where (obj ((k_i v_i) ...)) (hb-eval hx v_ctx))
   (side-condition (> (length (term (k_i ...))) 0))]

  ;; Empty array/object or falsy: render else block
  [(render-block "each" hx tmpl_body tmpl_else v_ctx)
   (render-template tmpl_else v_ctx)]

  ;; ── {{#with expr}}body{{else}}alt{{/with}} ──────────────────────
  [(render-block "with" hx tmpl_body tmpl_else v_ctx)
   (render-template tmpl_body v_merged)
   (where v_val (hb-eval hx v_ctx))
   (where #t (truthy/hbs v_val))
   (where v_merged (merge-context v_ctx v_val))]

  [(render-block "with" hx tmpl_body tmpl_else v_ctx)
   (render-template tmpl_else v_ctx)
   (where v_val (hb-eval hx v_ctx))
   (where #f (truthy/hbs v_val))])


;; ═══════════════════════════════════════════════════════════════════
;; render-each-arr: iterate over array elements
;; Binds: this=element, @index=i, @first=(i==0), @last=(i==max)
;; ═══════════════════════════════════════════════════════════════════

(define-metafunction Iidy-Handlebars
  render-each-arr : (v ...) tmpl v natural natural -> s

  [(render-each-arr () tmpl v_ctx natural_i natural_max) ""]

  [(render-each-arr (v_hd v_rest ...) tmpl v_ctx natural_i natural_max)
   ,(string-append (term s_hd) (term s_rest))
   (where v_item-ctx
          (obj (("this" v_hd)
                ("@index" (num natural_i))
                ("@first" (bool ,(if (zero? (term natural_i)) (term #t) (term #f))))
                ("@last" (bool ,(if (= (term natural_i) (term natural_max)) (term #t) (term #f)))))))
   (where v_merged (merge-context v_ctx v_item-ctx))
   (where s_hd (render-template tmpl v_merged))
   (where s_rest (render-each-arr (v_rest ...) tmpl v_ctx
                                  ,(add1 (term natural_i)) natural_max))])


;; ═══════════════════════════════════════════════════════════════════
;; render-each-obj: iterate over object entries
;; Binds: this=value, @key=key
;; ═══════════════════════════════════════════════════════════════════

(define-metafunction Iidy-Handlebars
  render-each-obj : ((k v) ...) tmpl v -> s

  [(render-each-obj () tmpl v_ctx) ""]

  [(render-each-obj ((k_hd v_hd) (k_rest v_rest) ...) tmpl v_ctx)
   ,(string-append (term s_hd) (term s_rest))
   (where v_item-ctx (obj (("this" v_hd) ("@key" (str k_hd)))))
   (where v_merged (merge-context v_ctx v_item-ctx))
   (where s_hd (render-template tmpl v_merged))
   (where s_rest (render-each-obj ((k_rest v_rest) ...) tmpl v_ctx))])
