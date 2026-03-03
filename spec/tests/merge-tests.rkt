#lang racket/base
;; Unit tests for merge metafunctions
;;
;; Tests: merge-objs, merge-all, concat-arrs, obj-from-pairs, val->text

(require redex/reduction-semantics
         rackunit
         "../lang/core.rkt"
         "../semantics/merge.rkt")

(provide merge-tests)

(define merge-tests
  (test-suite
   "Merge metafunctions"

   ;; ── merge-objs ─────────────────────────────────────────────────

   (test-suite
    "merge-objs"

    (test-case "merge two empty objects"
      (check-equal?
       (term (merge-objs (obj ()) (obj ())))
       (term (obj ()))))

    (test-case "merge empty into non-empty"
      (check-equal?
       (term (merge-objs (obj (("a" (num 1)))) (obj ())))
       (term (obj (("a" (num 1)))))))

    (test-case "merge non-empty into empty"
      (check-equal?
       (term (merge-objs (obj ()) (obj (("a" (num 1))))))
       (term (obj (("a" (num 1)))))))

    (test-case "disjoint keys"
      (check-equal?
       (term (merge-objs (obj (("a" (num 1))))
                         (obj (("b" (num 2))))))
       (term (obj (("a" (num 1)) ("b" (num 2)))))))

    (test-case "overlay wins on collision"
      (check-equal?
       (term (merge-objs (obj (("a" (num 1))))
                         (obj (("a" (num 99))))))
       (term (obj (("a" (num 99)))))))

    (test-case "base key order preserved"
      (check-equal?
       (term (merge-objs (obj (("z" (num 1)) ("a" (num 2))))
                         (obj (("m" (num 3))))))
       (term (obj (("z" (num 1)) ("a" (num 2)) ("m" (num 3)))))))

    (test-case "partial overlap preserves base order, overlay wins"
      (check-equal?
       (term (merge-objs (obj (("a" (num 1)) ("b" (num 2)) ("c" (num 3))))
                         (obj (("b" (num 99)) ("d" (num 4))))))
       (term (obj (("a" (num 1)) ("b" (num 99)) ("c" (num 3)) ("d" (num 4)))))))

    (test-case "deep value replacement (shallow merge)"
      (check-equal?
       (term (merge-objs (obj (("x" (obj (("inner" (num 1)))))))
                         (obj (("x" (num 42))))))
       (term (obj (("x" (num 42))))))))

   ;; ── merge-all ──────────────────────────────────────────────────

   (test-suite
    "merge-all"

    (test-case "merge-all empty list"
      (check-equal?
       (term (merge-all ()))
       (term (obj ()))))

    (test-case "merge-all single object"
      (check-equal?
       (term (merge-all ((obj (("a" (num 1)))))))
       (term (obj (("a" (num 1)))))))

    (test-case "merge-all two objects"
      (check-equal?
       (term (merge-all ((obj (("a" (num 1))))
                         (obj (("b" (num 2)))))))
       (term (obj (("a" (num 1)) ("b" (num 2)))))))

    (test-case "merge-all three with cascading overlap"
      (check-equal?
       (term (merge-all ((obj (("a" (num 1))))
                         (obj (("a" (num 2)) ("b" (num 2))))
                         (obj (("b" (num 3)) ("c" (num 3)))))))
       (term (obj (("a" (num 2)) ("b" (num 3)) ("c" (num 3))))))))

   ;; ── concat-arrs ────────────────────────────────────────────────

   (test-suite
    "concat-arrs"

    (test-case "concat two arrays"
      (check-equal?
       (term (concat-arrs ((arr ((num 1) (num 2)))
                           (arr ((num 3))))))
       (term (arr ((num 1) (num 2) (num 3))))))

    (test-case "concat with empty array"
      (check-equal?
       (term (concat-arrs ((arr ()) (arr ((num 1))))))
       (term (arr ((num 1))))))

    (test-case "concat empty list"
      (check-equal?
       (term (concat-arrs ()))
       (term (arr ()))))

    (test-case "non-array becomes singleton"
      (check-equal?
       (term (concat-arrs ((num 1) (arr ((num 2))) (num 3))))
       (term (arr ((num 1) (num 2) (num 3))))))

    (test-case "all non-arrays"
      (check-equal?
       (term (concat-arrs ((str "a") (str "b"))))
       (term (arr ((str "a") (str "b")))))))

   ;; ── obj-from-pairs ─────────────────────────────────────────────

   (test-suite
    "obj-from-pairs"

    (test-case "simple pairs"
      (check-equal?
       (term (obj-from-pairs
              (arr ((arr ((str "x") (num 1)))
                    (arr ((str "y") (num 2)))))))
       (term (obj (("x" (num 1)) ("y" (num 2)))))))

    (test-case "empty pairs"
      (check-equal?
       (term (obj-from-pairs (arr ())))
       (term (obj ()))))

    (test-case "single pair"
      (check-equal?
       (term (obj-from-pairs (arr ((arr ((str "key") (str "val")))))))
       (term (obj (("key" (str "val"))))))))

   ;; ── val->text ──────────────────────────────────────────────────

   (test-suite
    "val->text"

    (test-case "string passes through"
      (check-equal? (term (val->text (str "hello"))) "hello"))

    (test-case "true boolean"
      (check-equal? (term (val->text (bool #t))) "true"))

    (test-case "false boolean"
      (check-equal? (term (val->text (bool #f))) "false"))

    (test-case "null"
      (check-equal? (term (val->text null)) "null"))

    (test-case "integer number"
      (check-equal? (term (val->text (num 42))) "42"))

    (test-case "zero"
      (check-equal? (term (val->text (num 0))) "0"))

    (test-case "array produces string representation"
      (check-true (string? (term (val->text (arr ((num 1))))))))

    (test-case "object produces string representation"
      (check-true (string? (term (val->text (obj (("a" (num 1))))))))))))
