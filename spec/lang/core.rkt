#lang racket/base
;; Iidy-Core: Core value domain for iidy preprocessing language
;;
;; YAML is the host/concrete syntax. This grammar defines iidy's
;; semantic domain — the values that iidy expressions evaluate to.

(require redex/reduction-semantics)
(provide Iidy-Core)

(define-language Iidy-Core

  ;; ── Values (semantic domain) ──────────────────────────────────
  ;; These are the results of evaluating iidy expressions.
  ;; OObject preserves insertion order (list of pairs, not hash).

  (v ::= null
         (bool b)
         (num n)
         (str s)
         (arr (v ...))
         (obj ((k v) ...)))

  (b ::= #t #f)
  (n ::= number)
  (s ::= string)
  (k ::= string)

  ;; ── Environments ──────────────────────────────────────────────
  ;; Variable bindings: ordered association list.
  ;; Keys are strings (YAML mapping keys are always text).
  ;; Later entries shadow earlier ones (lookup searches right-to-left).

  (σ ::= ((string v) ...))

  ;; ── Template definitions (for !$expand) ───────────────────────
  ;; Placeholder: used by the expand rule (not yet implemented).
  (Σ ::= ((template-name template-body template-params) ...))
  (template-name ::= string)
  (template-body ::= string)
  (template-params ::= ((string v) ...)))
