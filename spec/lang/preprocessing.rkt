#lang racket/base
;; Iidy-Preprocess: Full preprocessing tag grammar
;;
;; Extends Iidy-Core with expression forms for all 22 preprocessing
;; tags. These are the AST nodes before evaluation — the "source language"
;; that gets evaluated down to Iidy-Core values.

(require redex/reduction-semantics
         "core.rkt")
(provide Iidy-Preprocess)

(define-extended-language Iidy-Preprocess Iidy-Core

  ;; ── Expressions (AST before evaluation) ───────────────────────
  ;;
  ;; Each form corresponds to an iidy preprocessing tag (!$...).
  ;; In YAML concrete syntax these are tagged nodes; here they are
  ;; s-expression AST nodes.
  ;;
  ;; var-name is a string (YAML keys are text): "item", "x", etc.

  (e ::=
     ;; ── Literals & structure ──────────────────────────────────
     v                                  ; literal value (already resolved)
     (seq (e ...))                      ; YAML sequence → evaluate each element
     (obj-e ((ke e) ...))               ; YAML mapping → evaluate each value

     ;; ── String interpolation ──────────────────────────────────
     (tpl s)                            ; Handlebars-templated string: "{{var}}"

     ;; ── Variable lookup (!$) ──────────────────────────────────
     (var path)                         ; !$ path.to.var
     (var-q path query)                 ; !$ path ? dot.query
     (var-j path jmespath)              ; !$ path @ jmespath-expr

     ;; ── Conditional (!$if) ────────────────────────────────────
     (if e e e)                         ; test, then, else

     ;; ── Binding (!$let) ───────────────────────────────────────
     (let ((var-name e) ...) e)         ; sequential bindings + body

     ;; ── Iteration (!$map) ─────────────────────────────────────
     (map e e var-name)                 ; items, template, loop-var
     (map-f e e var-name e)             ; items, template, loop-var, filter

     ;; ── Aggregation ───────────────────────────────────────────
     (concat (e ...))                   ; !$concat: flatten arrays
     (merge (e ...))                    ; !$merge: shallow-merge objects

     ;; ── Comparison ────────────────────────────────────────────
     (eq e e)                           ; !$eq: structural equality
     (not e)                            ; !$not: logical negation

     ;; ── String operations ─────────────────────────────────────
     (split e e)                        ; !$split: delimiter, string → array
     (join e e)                         ; !$join: delimiter, array → string

     ;; ── Compound iteration ────────────────────────────────────
     (concat-map e e var-name)          ; !$concatMap: map then flatten
     (concat-map-f e e var-name e)      ; !$concatMap with filter
     (merge-map e e var-name)           ; !$mergeMap: map then merge
     (map-list-to-hash e e var-name)    ; !$mapListToHash: pairs → object
     (map-list-to-hash-f e e var-name e) ; !$mapListToHash with filter
     (map-values e e var-name)          ; !$mapValues: transform object values
     (group-by e e var-name)            ; !$groupBy: group array by key fn

     ;; ── Pair/object construction ──────────────────────────────
     (from-pairs e)                     ; !$fromPairs: [[k,v],...] → object

     ;; ── Serialization ─────────────────────────────────────────
     (to-yaml e)                        ; !$toYamlString
     (parse-yaml e)                     ; !$parseYaml
     (to-json e)                        ; !$toJsonString
     (parse-json e)                     ; !$parseJson

     ;; ── Escape (!$escape) ─────────────────────────────────────
     (escape e)                         ; suppress tag resolution

     ;; ── Template expansion (!$expand) ─────────────────────────
     (expand e e)                       ; template-name, params

     ;; ── CloudFormation pass-through ───────────────────────────
     (cfn tag-name e))                  ; !Ref, !Sub, etc. → wrap as object

  ;; ── Sub-expression components ─────────────────────────────────

  ;; Variable paths: dot-separated segments
  (path   ::= (segment ...))
  (segment ::= string)

  ;; Variable binding name (always a string — YAML keys are text)
  (var-name ::= string)

  ;; Query and JMESPath are opaque strings at this grammar level;
  ;; their internal structure is defined in the sub-language modules.
  (query    ::= string)
  (jmespath ::= string)
  (tag-name ::= string)
  (ke       ::= string))
