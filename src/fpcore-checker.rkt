#lang racket

(require racket/extflonum)
(require "common.rkt" "tensor.rkt")
(provide *fpcores* fpcore-recursive
         fpcore? expr? check-fpcore syntax-e-rec)

(define *fpcores* (make-parameter '()))  ; previously run fpcores
(define fpcore-recursive #f)  ; 'check-expr sets this true if a recursive call is encountered

(define/contract (fpcore? thing)
  contract?
  (match thing
    [`(FPCore (,(? argument?) ...) ,props ... ,(? expr?)) (properties? props)]
    [`(FPCore ,(? symbol?) (,(? argument?) ...) ,props ... ,(? expr?)) (properties? props)]
    [_ false]))

(define (properties? props)
  (define-values (rest props*) (parse-properties props))
  (null? rest))

(define (argument? arg)
  (match arg
    [(? symbol? arg) true]
    [`(! ,props ... ,(? symbol?))
     (properties? props)]
    [`(,(? symbol?) ,(or (? number?) (? symbol?)) ...) true]
    [_ false]))

(define (expr? expr)
  (match expr
    [(? number?) true]
    [(? extflonum?) true]
    [(? constant?) true]
    [(? tensor?) true]
    [(? symbol?) true]
    [(list (? operator?) (? expr?) ...) true]
    [(list (? (curry dict-has-key? (*fpcores*))) (? expr?) ...) true]
    [`(if ,(? expr?) ,(? expr?) ,(? expr?)) true]
    [`(,(or 'let 'let*) ([,(? symbol?) ,(? expr?)] ...) ,(? expr?)) true]
    [`(,(or 'while 'while*) ,(? expr?) ([,(? symbol?) ,(? expr?) ,(? expr?)] ...) ,(? expr?)) true]
    [`(tensor ([,(? symbol?) ,(? expr?)] ...) ,(? expr?)) true]
    [`(tensor* ([,(? symbol?) ,(? expr?)] ...) ([,(? symbol?) ,(? expr?) ,(? expr?)] ...) ,(? expr?)) true]
    [`(,(or 'for 'for*) ([,(? symbol?) ,(? expr?)] ...) ([,(? symbol?) ,(? expr?) ,(? expr?)] ...) ,(? expr?)) true]
    [`(cast ,(? expr?)) true]
    [`(! ,props ... ,(? expr?)) (properties? props)]
    [`(digits ,(? number?) ,(? number?) ,(? number?)) true]
    [_ false]))

;; Types

(define fpcore-types '(boolean real tensor))
(define typename? (apply symbols fpcore-types))

(define/contract (type? type)
  (-> list? boolean?)
  (typename? (first type)))

(define (typename-equal? type1 name)
  (-> type? typename? boolean?)
  (equal? (first type1) name))

(define (make-type name . data)
  (-> typename? list? type?)
  (list* name data))

(define/match (operator-type* op args)
  [((or '- 'fabs 'exp 'exp2 'expm1 'log 'log10 'log2 'log1p 'sqrt
        'cbrt 'sin 'cos 'tan 'asin 'acos 'atan 'sinh 'cosh 'tanh
        'asinh 'acosh 'atanh 'erf 'erfc 'tgamma 'lgamma 'ceil 'floor
        'trunc 'round 'nearbyint 'cast)
    (list '(real)))
   '(real)]
  [((or '+ '- '* '/ 'pow 'hypot 'atan2 'fmod 'remainder 'fmax 'fmin 'fdim 'copysign)
    (list '(real) '(real)))
   '(real)]
  [('fma (list '(real) '(real) '(real))) '(real)]
  [((or '< '> '<= '>= '== '!=) (list '(real) ...)) '(boolean)]
  [((or 'isfinite 'isinf 'isnan 'isnormal 'signbit) (list '(real))) '(boolean)]
  [((or 'and 'or) (list '(boolean) ...)) '(boolean)]
  [('not (list '(boolean))) '(boolean)]
  [('array (list (or (? (curryr typename-equal? 'real) elems) (? (curryr typename-equal? 'boolean) elems) (? (curryr typename-equal? 'tensor) elems)) ...))
    (cond [(for/and ([i elems]) (typename-equal? i 'tensor)) `(tensor ,(add1 (second (argmin (λ (x) (second x)) elems))))]
          [else '(tensor 1)])]
  [('dim (list (? (curryr typename-equal? 'tensor)))) '(real)]
  [('size (list (? (curryr typename-equal? 'tensor)) '(real) ...)) '(real)]
  [('ref (list (list tensor (? integer? n)) (? (curryr typename-equal? 'real) sizes) ...)) 
    (let ([d (- n (length sizes))])
      (cond [(negative? d) (error 'operator-type* "Ref out of bounds")]
            [(zero? d) '((real) (boolean))]
            [else '(tensor d)]))]
  [(_ _) #f])

;; optimistic type checker. If a single arg type combination is valid and return first (hopefully, only)
;; this might cause issues. better type checking needed?
(define (operator-type op args)  
  (define types (for/list ([arg args])
                  (match arg
                    [(? type?) (list arg)]
                    [`(,(? type?) ...) arg])))
  (define arg-coords (apply cartesian-product types))
  (for/fold ([res #f]) ([args* arg-coords]) #:break res
    (operator-type* op args*)))

(define (fpcore-as-operator-type ident args)
  (match-define (list core (list in-type ...) out-type) (dict-ref (*fpcores*) ident))
  (define match? (for/and ([i in-type] [j args]) (equal? i j)))
  (cond 
    [(and match? (empty? out-type))   ; match recursive fpcore
      (set! fpcore-recursive #t)
      '((real) (boolean) (tensor))]   ; match previous fpcore
    [match? out-type]
    [else #f]))                       ; no match

(define/contract (check-expr stx ctx)
  (-> syntax? (dictof argument? type?) (cons/c expr? (or/c type? (listof type?))))
  (match (syntax-e stx)
    [(? number? val)
     (cons val '(real))]
    [(? extflonum? val)
     (cons val '(real))]
    [(? hex? val)
     (cons val '(real))]
    [(? constant? val)
     (cons val (match val [(or 'TRUE 'FALSE) '(boolean)] [_ '(real)]))]
    [(? symbol? var)
     (unless (dict-has-key? ctx var)
       (raise-syntax-error #f "Undefined variable" stx))
     (cons var (dict-ref ctx var))]
    [(list (app syntax-e 'digits) m e b)      ; (digits m e b)
     (define m* (check-expr m ctx)) 
     (define e* (check-expr e ctx))
     (define b* (check-expr b ctx))
     (unless (and (integer? (car m*)) (integer? (car e*)) (integer? (car b*)))
      (raise-syntax-error #f "Values of digits must be integers" stx))
      (unless (>= (car b*) 2)
        (raise-syntax-error #f "Base of digits must be greater than 1" stx))
     (cons `(digits ,(car m*) ,(car e*) ,(car b*)) '(real))]
    [(list (app syntax-e 'if) test ift iff) ; if 
     (define test* (check-expr test ctx))
     (unless (equal?(cdr test*) '(boolean))
       (raise-syntax-error #f "Conditional test must return a boolean" stx test))
     (define ift* (check-expr ift ctx))
     (define iff* (check-expr iff ctx))
     (define ift-type
      (match (cdr ift*)
        [(? type? type) (list type)]
        [`(,(? type?) ...) (cdr ift*)]))
     (define iff-type
      (match (cdr iff*)
        [(? type? type) (list type)]
        [`(,(? type?) ...) (cdr iff*)]))
     (unless (for/or ([i ift-type]) (set-member? iff-type i))
       (raise-syntax-error #f "Conditional branches must have same type" stx))
     (cons `(if ,(car test*) ,(car ift*) ,(car iff*)) (for/first ([i ift-type] #:when (set-member? iff-type i)) i))]
    [(cons (app syntax-e 'if) _)            ; if (invalid)
     (raise-syntax-error #f "Invalid conditional statement" stx)]
    [(list (app syntax-e 'let) (app syntax-e (list (app syntax-e (list vars vals)) ...)) body)  ; let
     (define vars*
       (for/list ([var vars])
         (unless (symbol? (syntax-e var))
           (raise-syntax-error #f "Only variables may be bound by let binding" stx var))
         (syntax-e var)))
     (define vals* (map (curryr check-expr ctx) vals))
     (define ctx* (apply dict-set* ctx (append-map list vars* (map cdr vals*))))
     (define body* (check-expr body ctx*))
     (cons `(let (,@(map list vars* (map car vals*))) ,(car body*)) (cdr body*))]
    [(list (app syntax-e 'let*) (app syntax-e (list (app syntax-e (list vars vals)) ...)) body)  ; let*
     (define vars*
       (for/list ([var vars])
         (unless (symbol? (syntax-e var))
           (raise-syntax-error #f "Only variables may be bound by let* binding" stx var))
         (syntax-e var)))
     (define-values (ctx* vals*)
       (for/fold ([ctx ctx] [vals '()]) ([var vars*] [val vals])
         (define val* (check-expr val ctx))
         (define ctx* (dict-set ctx var (cdr val*)))
         (values ctx* (cons val* vals))))
     (define body* (check-expr body ctx*))
     (cons `(let* (,@(map list vars* (map car (reverse vals*)))) ,(car body*)) (cdr body*))]
    [(cons (app syntax-e (or 'let 'let*)) _)                                                   ; let, let* (invalid)
     (raise-syntax-error #f "Invalid let bindings" stx)]
    [(list (app syntax-e 'while) test (app syntax-e (list (app syntax-e (list vars inits updates)) ...)) body) ; while
     (define vars*
       (for/list ([var vars])
         (unless (symbol? (syntax-e var))
           (raise-syntax-error #f "Only variables may be bound by while loop" stx var))
         (syntax-e var)))
     (define inits* (map (curryr check-expr ctx) inits))
     (define ctx* (apply dict-set* ctx (append-map list vars* (map cdr inits*))))
     (define test* (check-expr test ctx*))
     (unless (equal?(cdr test*) '(boolean))
       (raise-syntax-error #f "While loop conditions must return a boolean" test))
     (define updates* (map (curryr check-expr ctx*) updates))
     (for ([var vars] [init inits*] [update updates*])
       (unless (equal? (cdr init) (cdr update))
         (raise-syntax-error #f "Initialization and update must have the same type in while loop" stx var)))
     (define body* (check-expr body ctx*))
     (cons `(while ,(car test*) (,@(map list vars* (map car inits*) (map car updates*))) ,(car body*)) (cdr body*))]
    [(list (app syntax-e 'while*) test (app syntax-e (list (app syntax-e (list vars inits updates)) ...)) body) ; while*
     (define vars*
       (for/list ([var vars])
         (unless (symbol? (syntax-e var))
           (raise-syntax-error #f "Only variables may be bound by while loop" stx var))
         (syntax-e var)))
     (define-values (ctx* inits-rev)
       (for/fold ([ctx ctx] [inits* '()]) ([var vars*] [init inits])
         (define init* (check-expr init ctx))
         (define ctx* (dict-set ctx var (cdr init*)))
         (values ctx* (cons init* inits*))))
     (define inits* (reverse inits-rev))
     (define test* (check-expr test ctx*))
     (unless (equal?(cdr test*) '(boolean))
       (raise-syntax-error #f "While loop conditions must return a boolean" test))
     (define updates* (map (curryr check-expr ctx*) updates))
     (for ([var vars] [init inits*] [update updates*])
       (unless (equal? (cdr init) (cdr update))
         (raise-syntax-error #f "Initialization and update must have the same type in while loop" stx var)))
     (define body* (check-expr body ctx*))
     (cons `(while* ,(car test*) (,@(map list vars* (map car inits*) (map car updates*))) ,(car body*)) (cdr body*))]
    [(cons (app syntax-e (or 'while 'while*)) _)                 ; while, while* (invalid)
     (raise-syntax-error #f "Invalid while loop" stx)]
    [(list (app syntax-e 'for) (app syntax-e (list (app syntax-e (list vars vals)) ...)) (app syntax-e (list (app syntax-e (list accums inits updates)) ...)) body) ; for
     (define vars*
       (for/list ([var vars])
         (unless (symbol? (syntax-e var))
           (raise-syntax-error #f "Only variables may be bound by for binding" stx var))
         (syntax-e var)))
     (define vals* (map (curryr check-expr ctx) vals))
     (define ctx* (apply dict-set* ctx (append-map list vars* (map cdr vals*))))
     (define accums*
       (for/list ([accum accums])
         (unless (symbol? (syntax-e accum))
           (raise-syntax-error #f "Only variables may be bound by for binding" stx accum))
         (syntax-e accum)))
     (define inits* (map (curryr check-expr ctx) inits))
     (define ctx** (apply dict-set* ctx* (append-map list accums* (map cdr inits*))))
     (define updates* (map (curryr check-expr ctx**) updates))
     (for ([accum accums] [init inits*] [update updates*])
       (unless (equal? (cdr init) (cdr update))
         (raise-syntax-error #f "Initialization and update must have the same type in for loop" stx accum)))
     (define body* (check-expr body ctx**))
     (cons `(for (,@(map list vars* (map car (reverse vals*)))) (,@(map list accums* (map car inits*) (map car updates*))) ,(car body*)) (cdr body*))]
    [(list (app syntax-e 'for*) (app syntax-e (list (app syntax-e (list vars vals)) ...)) (app syntax-e (list (app syntax-e (list accums inits updates)) ...)) body) ; for*
     (define vars*
       (for/list ([var vars])
         (unless (symbol? (syntax-e var))
           (raise-syntax-error #f "Only variables may be bound by for binding" stx var))
         (syntax-e var)))
     (define vals* (map (curryr check-expr ctx) vals))
     (define ctx* (apply dict-set* ctx (append-map list vars* (map cdr vals*))))
     (define accums*
       (for/list ([accum accums])
         (unless (symbol? (syntax-e accum))
           (raise-syntax-error #f "Only variables may be bound by for binding" stx accum))
         (syntax-e accum)))
     (define-values (ctx** inits-rev)
       (for/fold ([ctx* ctx*] [inits* '()]) ([var accums*] [init inits])
         (define init* (check-expr init ctx*))
         (define ctx** (dict-set ctx* var (cdr init*)))
         (values ctx** (cons init* inits*))))
     (define inits* (reverse inits-rev))
     (define updates* (map (curryr check-expr ctx**) updates))
     (for ([accum accums] [init inits*] [update updates*])
       (unless (equal? (cdr init) (cdr update))
         (raise-syntax-error #f "Initialization and update must have the same type in for loop" stx accum)))
     (define body* (check-expr body ctx**))
     (cons `(for* (,@(map list vars* (map car (reverse vals*)))) (,@(map list accums* (map car inits*) (map car updates*))) ,(car body*)) (cdr body*))]
    [(cons (app syntax-e (or 'for 'for*)) _)               ; for, for* (invalid)
     (raise-syntax-error #f "Invalid for loop" stx)]
    [(list (app syntax-e 'tensor) (app syntax-e (list (app syntax-e (list vars vals)) ...)) body)  ; tensor
     (define vars*
       (for/list ([var vars])
         (unless (symbol? (syntax-e var))
           (raise-syntax-error #f "Only variables may be bound by tensor binding" stx var))
         (syntax-e var)))
     (define vals* (map (curryr check-expr ctx) vals))
     (define ctx* (apply dict-set* ctx (append-map list vars* (map cdr vals*))))
     (define body* (check-expr body ctx*))
     (cons `(tensor (,@(map list vars* (map car vals*))) ,(car body*)) `(tensor ,(length vars)))]
    [(list (app syntax-e 'tensor*) (app syntax-e (list (app syntax-e (list vars vals)) ...)) (app syntax-e (list (app syntax-e (list accums inits updates)) ...)) body)  ; tensor*
     (define vars*
       (for/list ([var vars])
         (unless (symbol? (syntax-e var))
           (raise-syntax-error #f "Only variables may be bound by tensor binding" stx var))
         (syntax-e var)))
     (define vals* (map (curryr check-expr ctx) vals))
     (define ctx* (apply dict-set* ctx (append-map list vars* (map cdr vals*))))
     (define accums*
       (for/list ([accum accums])
         (unless (symbol? (syntax-e accum))
           (raise-syntax-error #f "Only variables may be bound by tensor binding" stx accum))
         (syntax-e accum)))
     (define-values (ctx** inits-rev)
       (for/fold ([ctx* ctx*] [inits* '()]) ([var accums*] [init inits])
         (define init* (check-expr init ctx*))
         (define ctx** (dict-set ctx* var (cdr init*)))
         (values ctx** (cons init* inits*))))
     (define inits* (reverse inits-rev))
     (define updates* (map (curryr check-expr ctx**) updates))
     (for ([accum accums] [init inits*] [update updates*])
       (unless (equal? (cdr init) (cdr update))
         (raise-syntax-error #f "Initialization and update must have the same type in tensor loop" stx accum)))
     (define body* (check-expr body ctx**))
     (cons `(tensor* (,@(map list vars* (map car vals*))) (,@(map list accums* (map car inits*) (map car updates*))) ,(car body*)) `(tensor ,(length vars)))]
    [(cons (app syntax-e (or 'tensor 'tensor*)) _)               ; tensor tensor* (invalid)
     (raise-syntax-error #f "Invalid tensor construction" stx)]
    [(list (app syntax-e '!) props ... expr)                     ; !
     (define expr* (check-expr expr ctx))
     (define props* (map syntax-e props))
     (cons `(! ,@props* ,(car expr*)) (cdr expr*))]
    [(list op args ...)                                         ; ops
     (unless (or (set-member? operators (syntax-e op)) (dict-has-key? (*fpcores*) (syntax-e op)))
       (raise-syntax-error #f "Unknown operator" op))
     (define op* (syntax-e op))
     (define children (map (curryr check-expr ctx) args))
     (define rtype 
       (if (set-member? operators op*)
           (operator-type op* (map cdr children))
           (fpcore-as-operator-type op* (map cdr children))))
     (unless rtype
       (raise-syntax-error #f (format "Invalid types for operator ~a" op) stx))
     (cons (list* op* (map car children)) rtype)]))

(define (syntax-e-rec stx)
  (match (syntax-e stx)
    [`(,stx-elem ...) (map syntax-e-rec stx-elem)]
    [stx* stx*]))

(define (check-fpcore* name vars properties body stx)
  (define-values (annotated-args args in-types ctx)
    (for/fold ([annot-args '()] [args '()] [in-types '()] [ctx (hash)])
              ([var vars])
      (let ([var* (syntax-e-rec var)])
        (unless (argument? var*)
          (raise-syntax-error #f "FPCore parameters must be variables" stx var))
        (match var*
         [`(,(? symbol? name) ,(or (? number? sizes) (? symbol? sizes)) ...) 
          (let ([dim-sizes (for/list ([i (filter symbol? sizes)]) (list i (make-type 'real)))])
            (values (append annot-args (list var*)) 
                    (append args (list name) (filter symbol? sizes))
                    (append in-types (list (make-type 'tensor (length sizes)))) 
                    (apply hash-set* (hash-set* ctx name (make-type 'tensor (length sizes))) (apply append dim-sizes))))]
         [(? list?) 
          (values (append annot-args (list var*)) (append args (list (last var*))) 
                  (append in-types (list '(real))) (hash-set* ctx (list (last var*)) '(real)))]
         [_ (values (append annot-args (list var*)) (append args (list var*)) 
                    (append in-types (list '(real))) (hash-set* ctx var* '(real)))]))))

  (define properties*
    (let loop ([properties properties])
      (match properties
        [(list) (list)]
        [(list prop) (raise-syntax-error #f "Property with no value" prop)]
        [(list (app syntax-e (? property? prop)) value rest ...)
        (cons (cons prop value) (loop rest))]
        [(list prop _ ...) (raise-syntax-error #f "Invalid property" prop)])))

  (when (dict-has-key? properties* ':pre)
    (define pre (dict-ref properties* ':pre))
    (define pre* (check-expr pre ctx))
    (unless (equal? (cdr pre*) '(boolean))
      (raise-syntax-error #f "FPCore precondition must return a boolean" pre)))
  
  (when (non-empty-string? name)
    (*fpcores* (dict-set* (*fpcores*) (string->symbol name) (list '() in-types '()))))

  (define body* (check-expr body ctx)) ; Any type
  (define core*
    `(FPCore (,@annotated-args)
          ,@(apply append
                    (for/list ([(prop val) (in-dict properties*)])
                      (list prop (syntax->datum val))))
          ,(car body*)))

  (when (non-empty-string? name)  ; update hash with full core information
    (*fpcores* (dict-set* (*fpcores*) (string->symbol name) (list core* in-types (cdr body*)))))
  (when fpcore-recursive    ; check again, if recursive call encountered
    (set! fpcore-recursive #f)
    (check-expr body ctx))
  core*)

(define/contract (check-fpcore stx)
  (-> syntax? fpcore?)
  (match (syntax-e stx)
   [(list (app syntax-e 'FPCore) (app syntax-e name) (app syntax-e (list vars ...)) properties ... body)
    (unless (symbol? name)
      (raise-syntax-error #f "FPCore identifier must be a symbol" stx name))
    (check-fpcore* (symbol->string name) vars properties body stx)]
   [(list (app syntax-e 'FPCore) (app syntax-e (list vars ...)) properties ... body)
    (check-fpcore* "" vars properties body stx)]))