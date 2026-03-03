#lang racket/base
;; Truthiness predicates for iidy
;;
;; iidy has THREE distinct truthiness definitions:
;;   1. OValue truthiness (used by !$if, !$not, !$map filter)
;;   2. Handlebars truthiness (used inside {{#if ...}})
;;   3. JMESPath truthiness (used in [?filter] expressions)
;;
;; Key difference: iidy treats 0 as FALSY; Handlebars and JMESPath
;; treat all numbers as truthy (including 0).

(require redex/reduction-semantics
         "../lang/core.rkt")
(provide truthy truthy/hbs truthy/jmespath)

;; ── iidy OValue truthiness ──────────────────────────────────────
;; Used by: !$if test, !$not, !$map filter, !$concatMap filter
;;
;;   null        → #f
;;   (bool b)    → b
;;   (str s)     → s ≠ ""
;;   (num n)     → n ≠ 0      ← KEY: zero is falsy
;;   (arr (...)) → non-empty
;;   (obj (...)) → non-empty

(define-metafunction Iidy-Core
  truthy : v -> b

  [(truthy null)           #f]
  [(truthy (bool b))       b]
  [(truthy (str ""))       #f]
  [(truthy (str s))        #t]
  [(truthy (num 0))        #f]
  [(truthy (num n))        #t]
  [(truthy (arr ()))       #f]
  [(truthy (arr (v_1 v_rest ...))) #t]
  [(truthy (obj ()))       #f]
  [(truthy (obj ((k_1 v_1) (k_rest v_rest) ...))) #t])


;; ── Handlebars truthiness ───────────────────────────────────────
;; Used by: {{#if ...}}, {{#unless ...}} blocks
;;
;; Same as OValue EXCEPT: all numbers are truthy (even 0).
;; This matches the Handlebars.js specification.

(define-metafunction Iidy-Core
  truthy/hbs : v -> b

  [(truthy/hbs null)           #f]
  [(truthy/hbs (bool b))       b]
  [(truthy/hbs (str ""))       #f]
  [(truthy/hbs (str s))        #t]
  [(truthy/hbs (num n))        #t]           ; ← ALL numbers truthy
  [(truthy/hbs (arr ()))       #f]
  [(truthy/hbs (arr (v_1 v_rest ...))) #t]
  [(truthy/hbs (obj ()))       #f]
  [(truthy/hbs (obj ((k_1 v_1) (k_rest v_rest) ...))) #t])


;; ── JMESPath truthiness ─────────────────────────────────────────
;; Used by: [?filter] expressions in JMESPath queries
;;
;; Currently identical to Handlebars truthiness. Kept as a separate
;; metafunction for two reasons:
;;   1. The JMESPath and Handlebars specs define truthiness independently
;;   2. Future divergence is possible if either spec changes
;; This matches the JMESPath specification.

(define-metafunction Iidy-Core
  truthy/jmespath : v -> b

  [(truthy/jmespath null)           #f]
  [(truthy/jmespath (bool b))       b]
  [(truthy/jmespath (str ""))       #f]
  [(truthy/jmespath (str s))        #t]
  [(truthy/jmespath (num n))        #t]      ; ← ALL numbers truthy
  [(truthy/jmespath (arr ()))       #f]
  [(truthy/jmespath (arr (v_1 v_rest ...))) #t]
  [(truthy/jmespath (obj ()))       #f]
  [(truthy/jmespath (obj ((k_1 v_1) (k_rest v_rest) ...))) #t])
