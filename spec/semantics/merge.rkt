#lang racket/base
;; Merge operations for iidy preprocessing
;;
;; Implements:
;;   - merge-objs: shallow right-biased merge of two objects
;;   - merge-all: fold merge over a list of objects
;;   - concat-arrs: flatten/concatenate arrays
;;   - obj-from-pairs: build object from [[key, value], ...] pairs
;;   - val->text: convert value to text (for key coercion)

(require redex/reduction-semantics
         racket/match
         "../lang/core.rkt")
(provide merge-objs merge-all
         concat-arrs
         obj-from-pairs
         val->text)


;; ── merge-objs: shallow right-biased merge ──────────────────────
;; Base keys kept in order; overlay updates existing or appends new.
;; This matches iidy's mergeOObjects: overlay wins on collision,
;; base order preserved, new overlay keys appended.

(define-metafunction Iidy-Core
  merge-objs : v v -> v

  [(merge-objs (obj ((k_b v_b) ...)) (obj ((k_o v_o) ...)))
   (obj ,(let ([base (term ((k_b v_b) ...))]
              [overlay (term ((k_o v_o) ...))])
           ;; Update base keys with overlay values where present
           (let ([updated
                  (map (lambda (pair)
                         (let ([k (car pair)]
                               [v (cadr pair)])
                           (let ([found (assoc k overlay)])
                             (if found
                                 (list k (cadr found))
                                 (list k v)))))
                       base)]
                 [base-keys (map car base)])
             ;; Append overlay keys not in base
             (append updated
                     (filter (lambda (pair) (not (member (car pair) base-keys)))
                             overlay)))))])


;; ── merge-all: fold merge-objs over a list ──────────────────────

(define-metafunction Iidy-Core
  merge-all : (v ...) -> v

  [(merge-all ())
   (obj ())]

  [(merge-all (v_1))
   v_1]

  [(merge-all (v_1 v_2 v_rest ...))
   (merge-all ((merge-objs v_1 v_2) v_rest ...))])


;; ── concat-arrs: concatenate arrays ─────────────────────────────
;; Non-array values become singletons (matching iidy behavior).

(define-metafunction Iidy-Core
  concat-arrs : (v ...) -> v

  [(concat-arrs (v_items ...))
   (arr ,(apply append
                (map (lambda (item)
                       (match item
                         [`(arr ,elems) elems]
                         [other (list other)]))
                     (term (v_items ...)))))])


;; ── obj-from-pairs: [[k, v], ...] → object ─────────────────────

(define-metafunction Iidy-Core
  obj-from-pairs : v -> v

  [(obj-from-pairs (arr ((arr ((str string_k) v_v)) ...)))
   (obj ((string_k v_v) ...))])


;; ── val->text: convert a value to its text representation ───────
;; Used for: key coercion in mapListToHash, join, etc.

(define-metafunction Iidy-Core
  val->text : v -> string

  [(val->text (str s))    s]
  [(val->text (bool #t))  "true"]
  [(val->text (bool #f))  "false"]
  [(val->text null)       "null"]
  [(val->text (num n))    ,(number->string (term n))]
  ;; Arrays and objects stringify to their Racket representation.
  ;; (In the Haskell implementation, these use Haskell's show.)
  [(val->text (arr any))  ,(format "~a" (term (arr any)))]
  [(val->text (obj any))  ,(format "~a" (term (obj any)))])
