#lang racket/base
;; Iidy-JMESPath: JMESPath query sub-language grammar
;;
;; Defines the AST for parsed JMESPath expressions used in iidy's
;; variable lookup with query: !$ path @ jmespath-expr
;;
;; iidy implements a SUBSET of JMESPath (no slice, no functions).
;; This grammar covers the implemented subset.
;;
;; Supported: field access, array indexing, sub-expressions, wildcard,
;; projections, flatten, filter, multi-select (hash/list), literals,
;; pipe, identity (@), comparisons, negation.

(require redex/reduction-semantics
         "core.rkt")
(provide Iidy-JMESPath)

(define-extended-language Iidy-JMESPath Iidy-Core

  ;; ── JMESPath expressions ────────────────────────────────────────
  (jx ::=
      (jfield s)                               ; field access: foo
      (jindex i)                               ; array index: [5], [-1]
      (jsub jx jx)                             ; sub-expression: a.b
      jwildcard                                ; * (object values / array pass-through)
      (jproj jx jx)                            ; projection: source[*].rhs
      (jflatten jx)                            ; flatten: expr[]
      (jfilter jx jx)                          ; filter: [?cond].proj
      (jmulti-hash ((s jx) ...))               ; {a: expr, b: expr}
      (jmulti-list (jx ...))                   ; [expr, expr]
      (jlit v)                                 ; literal: `"value"`
      (jpipe jx jx)                            ; pipe: a | b
      jidentity                                ; @ (current node)
      (jcmp cmp-op jx jx)                      ; comparison
      (jnot jx))                               ; negation: !expr

  ;; ── Comparison operators ────────────────────────────────────────
  (cmp-op ::= == != < <= > >=)

  ;; ── Integer index (supports negative) ───────────────────────────
  (i ::= integer))
