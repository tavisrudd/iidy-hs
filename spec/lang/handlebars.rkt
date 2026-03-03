#lang racket/base
;; Iidy-Handlebars: Handlebars template sub-language grammar
;;
;; Defines the AST for parsed Handlebars templates used in iidy's
;; string interpolation (any YAML string containing "{{...}}").
;;
;; This is a PARSED representation — the concrete syntax is the
;; Handlebars template string; this grammar defines what it parses TO.
;; Parsing is outside the formal model's scope (it's a string operation).
;;
;; The template engine supports:
;;   - Variable interpolation: {{path.to.var}}
;;   - Block helpers: {{#if}}, {{#unless}}, {{#each}}, {{#with}}
;;   - Helper functions: {{toLowerCase name}}, {{toJson obj}}
;;   - Literals: {{"string"}}, {{123}}, {{true}}
;;   - Comments: {{! this is ignored }}

(require redex/reduction-semantics
         "core.rkt")
(provide Iidy-Handlebars)

(define-extended-language Iidy-Handlebars Iidy-Core

  ;; ── Template ────────────────────────────────────────────────────
  ;; A parsed template is a list of parts.
  (tmpl ::= (tp ...))

  ;; ── Template parts ──────────────────────────────────────────────
  (tp ::=
      (hb-literal s)                           ; raw text passthrough
      (hb-output hx)                           ; {{expr}} — interpolate
      (hb-block block-kind hx tmpl tmpl)       ; {{#kind expr}}body{{else}}alt{{/kind}}
      hb-comment)                              ; {{! ... }}

  ;; ── Handlebars expressions ──────────────────────────────────────
  (hx ::=
      (hb-path (s ...))                        ; dot-path: a.b.c → ("a" "b" "c")
      (hb-lit-str s)                           ; string literal
      (hb-lit-num n)                           ; number literal
      (hb-lit-bool b)                          ; boolean literal
      (hb-helper s (hx ...)))                  ; helper call: name(args...)

  ;; ── Block helper kinds ──────────────────────────────────────────
  ;; The four block helpers supported by iidy's Handlebars engine.
  (block-kind ::= "if" "unless" "each" "with"))
