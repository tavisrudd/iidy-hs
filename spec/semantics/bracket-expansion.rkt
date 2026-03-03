#lang racket/base
;; Bracket expansion for iidy variable paths
;;
;; In iidy, variable paths can contain bracket references:
;;   config[env].host  →  config.production.host  (if env="production")
;;
;; Bracket expansion resolves [varName] segments by looking up
;; varName in the environment and substituting its string value.
;;
;; In the formal model, we represent bracket references explicitly
;; as (bracket-ref "varName") segments rather than parsing strings.
;; This separates the expansion semantics from string parsing.
;;
;; Expansion is recursive with a depth limit of 10 to prevent
;; infinite loops (matching the Haskell implementation).

(require redex/reduction-semantics
         "../lang/core.rkt"
         "env.rkt"
         "merge.rkt")
(provide expand-path Iidy-BracketExpansion)


;; ═══════════════════════════════════════════════════════════════════
;; Extended language with bracket references in paths
;; ═══════════════════════════════════════════════════════════════════

(define-extended-language Iidy-BracketExpansion Iidy-Core

  ;; A path with possible bracket references
  (bpath    ::= (bsegment ...))
  (bsegment ::= string                        ; literal segment
                (bracket-ref string)))          ; [varName] — resolve from env


;; ═══════════════════════════════════════════════════════════════════
;; expand-path: resolve bracket references in a path
;;
;; Each (bracket-ref "name") is replaced by the string value of
;; looking up "name" in σ. The result of expansion may itself
;; introduce dot-separated segments (if the value contains dots).
;;
;; Returns a flat list of string segments (no bracket-refs).
;; ═══════════════════════════════════════════════════════════════════

(define-metafunction Iidy-BracketExpansion
  expand-path : bpath σ -> (string ...)

  ;; Empty path
  [(expand-path () σ)
   ()]

  ;; Literal segment: keep as-is
  [(expand-path (string_seg bsegment_rest ...) σ)
   (string_seg string_out ...)
   (where (string_out ...) (expand-path (bsegment_rest ...) σ))]

  ;; Bracket reference: look up variable, convert to string, use as segment
  [(expand-path ((bracket-ref string_var) bsegment_rest ...) σ)
   (string_val string_out ...)
   (where v_val (lookup-for-bracket string_var σ))
   (where string_val (val->text-for-bracket v_val))
   (where (string_out ...) (expand-path (bsegment_rest ...) σ))])


;; ═══════════════════════════════════════════════════════════════════
;; lookup-for-bracket: look up a variable for bracket expansion
;; Returns the value or null if not found.
;; ═══════════════════════════════════════════════════════════════════

(define-metafunction Iidy-BracketExpansion
  lookup-for-bracket : string σ -> v

  [(lookup-for-bracket string_k σ)
   ,(let ([result (term (lookup string_k σ))])
      (if (equal? result (term unbound))
          (term null)
          result))])


;; ═══════════════════════════════════════════════════════════════════
;; val->text-for-bracket: convert a value to a string segment
;; ═══════════════════════════════════════════════════════════════════

(define-metafunction Iidy-BracketExpansion
  val->text-for-bracket : v -> string

  [(val->text-for-bracket (str s))    s]
  [(val->text-for-bracket (num n))    ,(number->string (term n))]
  [(val->text-for-bracket (bool #t))  "true"]
  [(val->text-for-bracket (bool #f))  "false"]
  [(val->text-for-bracket null)       "null"]
  [(val->text-for-bracket v)          ,(format "~a" (term v))])
