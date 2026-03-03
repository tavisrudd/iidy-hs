#lang racket/base
;; Tests for Handlebars template rendering semantics

(require rackunit
         redex/reduction-semantics
         "../lang/core.rkt"
         "../lang/handlebars.rkt"
         "../semantics/handlebars-eval.rkt")
(provide handlebars-tests)


;; ═══════════════════════════════════════════════════════════════════
;; Grammar tests
;; ═══════════════════════════════════════════════════════════════════

(define grammar-tests
  (test-suite
   "Handlebars grammar"

   (test-case "literal part"
     (check-not-false
      (redex-match? Iidy-Handlebars tp (term (hb-literal "hello")))))

   (test-case "output part with path"
     (check-not-false
      (redex-match? Iidy-Handlebars tp (term (hb-output (hb-path ("name")))))))

   (test-case "block part"
     (check-not-false
      (redex-match? Iidy-Handlebars tp
                    (term (hb-block "if" (hb-path ("show"))
                                   ((hb-literal "yes"))
                                   ((hb-literal "no")))))))

   (test-case "comment"
     (check-not-false
      (redex-match? Iidy-Handlebars tp (term hb-comment))))

   (test-case "helper expression"
     (check-not-false
      (redex-match? Iidy-Handlebars hx
                    (term (hb-helper "toLowerCase" ((hb-path ("name"))))))))

   (test-case "full template"
     (check-not-false
      (redex-match? Iidy-Handlebars tmpl
                    (term ((hb-literal "Hello, ")
                           (hb-output (hb-path ("name")))
                           (hb-literal "!"))))))))


;; ═══════════════════════════════════════════════════════════════════
;; Lookup tests
;; ═══════════════════════════════════════════════════════════════════

(define lookup-tests
  (test-suite
   "hb-lookup"

   (test-case "simple field"
     (check-equal?
      (term (hb-lookup ("name") (obj (("name" (str "Alice"))))))
      (term (str "Alice"))))

   (test-case "nested path"
     (check-equal?
      (term (hb-lookup ("config" "db" "host")
                       (obj (("config" (obj (("db" (obj (("host" (str "localhost"))))))))))))
      (term (str "localhost"))))

   (test-case "array index"
     (check-equal?
      (term (hb-lookup ("items" "1")
                       (obj (("items" (arr ((str "a") (str "b") (str "c"))))))))
      (term (str "b"))))

   (test-case "missing field returns null"
     (check-equal?
      (term (hb-lookup ("missing") (obj (("name" (str "x"))))))
      (term null)))

   (test-case "traverse into non-container returns null"
     (check-equal?
      (term (hb-lookup ("x" "y") (obj (("x" (str "flat"))))))
      (term null)))

   (test-case "empty path returns value"
     (check-equal?
      (term (hb-lookup () (str "hello")))
      (term (str "hello"))))))


;; ═══════════════════════════════════════════════════════════════════
;; Expression evaluation tests
;; ═══════════════════════════════════════════════════════════════════

(define eval-tests
  (test-suite
   "hb-eval"

   (test-case "path lookup"
     (check-equal?
      (term (hb-eval (hb-path ("name")) (obj (("name" (str "Alice"))))))
      (term (str "Alice"))))

   (test-case "string literal"
     (check-equal?
      (term (hb-eval (hb-lit-str "hello") (obj ())))
      (term (str "hello"))))

   (test-case "number literal"
     (check-equal?
      (term (hb-eval (hb-lit-num 42) (obj ())))
      (term (num 42))))

   (test-case "boolean literal"
     (check-equal?
      (term (hb-eval (hb-lit-bool #t) (obj ())))
      (term (bool #t))))

   (test-case "helper: toLowerCase"
     (check-equal?
      (term (hb-eval (hb-helper "toLowerCase" ((hb-path ("name"))))
                     (obj (("name" (str "ALICE"))))))
      (term (str "alice"))))

   (test-case "helper: toUpperCase"
     (check-equal?
      (term (hb-eval (hb-helper "toUpperCase" ((hb-lit-str "hello")))
                     (obj ())))
      (term (str "HELLO"))))

   (test-case "helper: eq (equal)"
     (check-equal?
      (term (hb-eval (hb-helper "eq" ((hb-lit-num 1) (hb-lit-num 1)))
                     (obj ())))
      (term (bool #t))))

   (test-case "helper: eq (not equal)"
     (check-equal?
      (term (hb-eval (hb-helper "eq" ((hb-lit-str "a") (hb-lit-str "b")))
                     (obj ())))
      (term (bool #f))))

   (test-case "helper: length (array)"
     (check-equal?
      (term (hb-eval (hb-helper "length" ((hb-path ("items"))))
                     (obj (("items" (arr ((num 1) (num 2) (num 3))))))))
      (term (num 3))))

   (test-case "helper: length (string)"
     (check-equal?
      (term (hb-eval (hb-helper "length" ((hb-lit-str "hello")))
                     (obj ())))
      (term (num 5))))

   (test-case "helper: lookup"
     (check-equal?
      (term (hb-eval (hb-helper "lookup" ((hb-path ("data")) (hb-lit-str "x")))
                     (obj (("data" (obj (("x" (num 42)) ("y" (num 99)))))))))
      (term (num 42))))

   (test-case "unknown helper returns null"
     (check-equal?
      (term (hb-eval (hb-helper "unknownHelper" ((hb-lit-str "x")))
                     (obj ())))
      (term null)))))


;; ═══════════════════════════════════════════════════════════════════
;; Template rendering tests
;; ═══════════════════════════════════════════════════════════════════

(define render-tests
  (test-suite
   "render-template"

   (test-case "empty template"
     (check-equal?
      (term (render-template () (obj ())))
      ""))

   (test-case "literal only"
     (check-equal?
      (term (render-template ((hb-literal "hello world")) (obj ())))
      "hello world"))

   (test-case "simple interpolation"
     (check-equal?
      (term (render-template
             ((hb-literal "Hello, ") (hb-output (hb-path ("name"))) (hb-literal "!"))
             (obj (("name" (str "Alice"))))))
      "Hello, Alice!"))

   (test-case "nested path interpolation"
     (check-equal?
      (term (render-template
             ((hb-output (hb-path ("config" "region"))))
             (obj (("config" (obj (("region" (str "us-west-2")))))))))
      "us-west-2"))

   (test-case "number interpolation"
     (check-equal?
      (term (render-template
             ((hb-literal "count: ") (hb-output (hb-path ("n"))))
             (obj (("n" (num 42))))))
      "count: 42"))

   (test-case "null interpolation produces empty string"
     (check-equal?
      (term (render-template
             ((hb-literal "val=") (hb-output (hb-path ("missing"))))
             (obj ())))
      "val="))

   (test-case "comment produces no output"
     (check-equal?
      (term (render-template
             ((hb-literal "a") hb-comment (hb-literal "b"))
             (obj ())))
      "ab"))

   (test-case "if block — truthy"
     (check-equal?
      (term (render-template
             ((hb-block "if" (hb-path ("show"))
                        ((hb-literal "visible"))
                        ((hb-literal "hidden"))))
             (obj (("show" (bool #t))))))
      "visible"))

   (test-case "if block — falsy"
     (check-equal?
      (term (render-template
             ((hb-block "if" (hb-path ("show"))
                        ((hb-literal "visible"))
                        ((hb-literal "hidden"))))
             (obj (("show" (bool #f))))))
      "hidden"))

   (test-case "if block — zero is truthy (Handlebars semantics)"
     (check-equal?
      (term (render-template
             ((hb-block "if" (hb-path ("count"))
                        ((hb-literal "yes"))
                        ((hb-literal "no"))))
             (obj (("count" (num 0))))))
      "yes"))

   (test-case "unless block — falsy renders body"
     (check-equal?
      (term (render-template
             ((hb-block "unless" (hb-path ("hidden"))
                        ((hb-literal "shown"))
                        ()))
             (obj (("hidden" (bool #f))))))
      "shown"))

   (test-case "unless block — truthy renders else"
     (check-equal?
      (term (render-template
             ((hb-block "unless" (hb-path ("hidden"))
                        ((hb-literal "shown"))
                        ((hb-literal "alt"))))
             (obj (("hidden" (bool #t))))))
      "alt"))

   (test-case "each block — array"
     (check-equal?
      (term (render-template
             ((hb-block "each" (hb-path ("items"))
                        ((hb-output (hb-path ("this"))) (hb-literal ","))
                        ()))
             (obj (("items" (arr ((str "a") (str "b") (str "c"))))))))
      "a,b,c,"))

   (test-case "each block — array with @index"
     (check-equal?
      (term (render-template
             ((hb-block "each" (hb-path ("items"))
                        ((hb-output (hb-path ("@index"))) (hb-literal ":") (hb-output (hb-path ("this"))) (hb-literal " "))
                        ()))
             (obj (("items" (arr ((str "a") (str "b"))))))))
      "0:a 1:b "))

   (test-case "each block — array @first/@last"
     (check-equal?
      (term (render-template
             ((hb-block "each" (hb-path ("items"))
                        ((hb-block "if" (hb-path ("@first"))
                                   ((hb-literal "["))
                                   ())
                         (hb-output (hb-path ("this")))
                         (hb-block "if" (hb-path ("@last"))
                                   ((hb-literal "]"))
                                   ((hb-literal ","))))
                        ()))
             (obj (("items" (arr ((str "x") (str "y") (str "z"))))))))
      "[x,y,z]"))

   (test-case "each block — object with @key"
     (check-equal?
      (term (render-template
             ((hb-block "each" (hb-path ("data"))
                        ((hb-output (hb-path ("@key"))) (hb-literal "=") (hb-output (hb-path ("this"))) (hb-literal " "))
                        ()))
             (obj (("data" (obj (("a" (num 1)) ("b" (num 2)))))))))
      "a=1 b=2 "))

   (test-case "each block — empty array renders else"
     (check-equal?
      (term (render-template
             ((hb-block "each" (hb-path ("items"))
                        ((hb-literal "item"))
                        ((hb-literal "none"))))
             (obj (("items" (arr ()))))))
      "none"))

   (test-case "with block — truthy"
     (check-equal?
      (term (render-template
             ((hb-block "with" (hb-path ("person"))
                        ((hb-output (hb-path ("name"))))
                        ()))
             (obj (("person" (obj (("name" (str "Bob")))))))))
      "Bob"))

   (test-case "with block — falsy renders else"
     (check-equal?
      (term (render-template
             ((hb-block "with" (hb-path ("person"))
                        ((hb-literal "found"))
                        ((hb-literal "not found"))))
             (obj (("person" null)))))
      "not found"))

   (test-case "helper in output"
     (check-equal?
      (term (render-template
             ((hb-output (hb-helper "toUpperCase" ((hb-path ("name"))))))
             (obj (("name" (str "alice"))))))
      "ALICE"))

   (test-case "nested blocks"
     (check-equal?
      (term (render-template
             ((hb-block "if" (hb-path ("logged-in"))
                        ((hb-literal "Welcome, ")
                         (hb-block "with" (hb-path ("user"))
                                   ((hb-output (hb-path ("name"))))
                                   ())
                         (hb-literal "!"))
                        ((hb-literal "Please log in"))))
             (obj (("logged-in" (bool #t))
                   ("user" (obj (("name" (str "Carol")))))))))
      "Welcome, Carol!"))))


;; ═══════════════════════════════════════════════════════════════════
;; val->text tests
;; ═══════════════════════════════════════════════════════════════════

(define val-text-tests
  (test-suite
   "hb-val->text"

   (test-case "string"  (check-equal? (term (hb-val->text (str "hi"))) "hi"))
   (test-case "true"    (check-equal? (term (hb-val->text (bool #t))) "true"))
   (test-case "false"   (check-equal? (term (hb-val->text (bool #f))) "false"))
   (test-case "null"    (check-equal? (term (hb-val->text null)) ""))
   (test-case "integer" (check-equal? (term (hb-val->text (num 42))) "42"))
   (test-case "float"   (check-equal? (term (hb-val->text (num 3.14))) "3.14"))))


;; ═══════════════════════════════════════════════════════════════════
;; Master test suite
;; ═══════════════════════════════════════════════════════════════════

(define handlebars-tests
  (test-suite
   "Handlebars sub-language"
   grammar-tests
   lookup-tests
   eval-tests
   render-tests
   val-text-tests))
