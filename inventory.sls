;;; inventory.sls --- Tree data structure modeling a hierarchical namespace

;; Copyright (C) 2009 Andreas Rottmann <a.rottmann@gmx.at>

;; Author: Andreas Rottmann <a.rottmann@gmx.at>

;; This program is free software; you can redistribute it and/or
;; modify it under the terms of the GNU General Public License
;; as published by the Free Software Foundation; either version 3
;; of the License, or (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program. If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;;; Code:
#!r6rs

(library (dorodango inventory)
  (export make-inventory
          inventory?
          inventory-leaf?
          inventory-container?
          inventory-empty?
          inventory-name
          inventory-data

          inventory-open
          inventory-enter
          inventory-leave
          inventory-leave-n
          inventory-next
          inventory-previous
          inventory-top

          in-inventory
          
          inventory-insert
          inventory-delete
          inventory-relabel
          
          inventory-ref
          inventory-ref-data
          inventory-update

          merge-inventories
          
          make-inventory-mapper
          inventory-mapper?
          inventory-mapper-map-leaf
          inventory-mapper-map-container
          apply-inventory-mapper)
  (import (rnrs)
          (srfi :8 receive)
          (spells foof-loop)
          (spells tracing)
          (spells zipper-tree))


;;; Constructors and deconstructors

(define-record-type item
  (fields name data))

(define (make-inventory name data)
  (make-zipper (list (make-item name data))))

(define (make-node name container?  data)
  (let ((item (make-item name data)))
    (if container? (list item) item)))

(define (rename-node node name)
  (if (pair? node)
      (cons (make-item name (item-data (car node))) (cdr node))
      (make-item name (item-data node))))

(define (inventory? thing)
  (and (zipper? thing)
       (let ((node (zipper-node thing)))
         (or (item? node)
             (and (pair? node)
                  (item? (car node)))))))

(define (inventory-container? inventory)
  (pair? (zipper-node inventory)))

(define (inventory-empty? inventory)
  (null? (cdr (zipper-node inventory))))

(define (inventory-leaf? inventory)
  (not (inventory-container? inventory)))

(define (inventory-item inventory)
  (if (inventory-leaf? inventory)
      (zipper-node inventory)
      (car (zipper-node inventory))))

(define (inventory-name inventory)
  (item-name (inventory-item inventory)))

(define (inventory-data inventory)
  (item-data (inventory-item inventory)))

;;; Navigation

(define (inventory-open inventory)
  (zip-down inventory))

(define (inventory-enter inventory)
  (zip-right (zip-down inventory)))

(define (inventory-leave inventory)
  (zip-up inventory))

(define (inventory-leave-n inventory n)
  (if (= n 0)
      inventory
      (inventory-leave-n (zip-up inventory) (- n 1))))

(define (inventory-next inventory)
  (zip-right inventory))

(define (inventory-previous inventory)
  (zip-left inventory))

(define (inventory-top inventory)
  (zip-top inventory))

;;@ Foof-loop iterator for inventories
(define-syntax in-inventory
  (syntax-rules (result)
    ((_ (item-var) (inventory-expr) cont . env)
     (cont
      (((inventory) inventory-expr))     ;Outer bindings
      ((item-var (inventory-enter inventory)
                 (inventory-next item-var))) ;Loop variables
      ()                                 ;Entry bindings
      ((not item-var))                   ;Termination conditions
      ()                                 ;Body bindings
      ()                                 ;Final bindings
      . env))
    ((_ (item-var) (inventory-expr (result result-var)) cont . env)
     (cont
      (((inventory contents)
        (let ((inventory inventory-expr))
          (values inventory (inventory-enter inventory))))) ;Outer bindings
      ((item-var contents next)
       (cursor contents (or next item-var)))         ;Loop variables
      ()                    ;Entry bindings
      ((not item-var))                   ;Termination conditions
      (((next) (inventory-next item-var))) ;Body bindings
      (((result-var) (if cursor
                         (inventory-leave cursor)
                         inventory))) ;Final bindings
      . env))))

(define (inventory-ref/aux inventory path not-found)
  (loop continue ((for path-elt path-rest (in-list path))
                  (with cursor inventory))
    => cursor
    (cond ((and (inventory-container? cursor)
                (loop next-child ((for child (in-inventory cursor)))
                  => #f
                  (if (string=? path-elt (inventory-name child))
                      child
                      (next-child))))
           => (lambda (child)
                (continue (=> cursor child))))
          (else
           (not-found cursor path-rest)))))

(define (inventory-ref inventory path)
  (inventory-ref/aux inventory path (lambda (node path) #f)))

(define (inventory-ref-data inventory path default)
  (cond ((inventory-ref inventory path) => inventory-data)
        (else default)))

;;; Manipulation

(define (inventory-insert-down inventory node)
  (zip-right (zip-insert-right (zip-down inventory) node)))

(define inventory-insert
  (case-lambda
    ((inventory other)
     (zip-insert-right inventory (zipper-node other)))
    ((inventory name container? data)
     (zip-insert-right inventory (make-node name container? data)))))

(define (inventory-relabel inventory name data)
  (zip-up (zip-change (zip-down inventory) (make-item name data))))

(define (inventory-update/aux inventory path other-node)
  (define (lose msg . irritants)
    (apply error 'inventory-update msg irritants))
  (define (adder node path-rest)
    (if (inventory-leaf? node)
        (lose "unexpected leaf node (expected container)"
              inventory path)
        (if (null? (cdr path-rest))
            (inventory-insert-down node (rename-node other-node (car path-rest)))
            (inventory-update/aux
             (inventory-insert-down node (make-node (car path-rest) #t #f))
             (cdr path-rest)
             other-node))))
  (inventory-ref/aux inventory path adder))

(define inventory-update
  (case-lambda
    ((inventory path other)
     (inventory-update/aux inventory path (zipper-node other)))
    ((inventory path container? data)
     (inventory-update/aux inventory path (make-node #f container? data)))))

(define (inventory-delete inventory)
  (if (zip-leftmost? inventory)
      (assertion-violation 'inventory-delete
                           "cannot delete container info"
                           inventory)
      (let ((cursor (zip-delete inventory)))
        (values (zip-leftmost? cursor) cursor))))

(define (merge-inventories a-inventory b-inventory conflict)
  (loop continue ((with to a-inventory)
                  (for from (in-inventory b-inventory)))
    => to
    (let ((leaf? (inventory-leaf? from))
          (cursor (inventory-ref to (list (inventory-name from)))))
      (continue
       (=> to
           (if leaf?
               (if cursor
                   (conflict cursor from)
                   (inventory-leave
                    (inventory-insert (inventory-open to) from)))
               (cond ((and cursor (inventory-leaf? cursor))
                      (conflict cursor from))
                     (cursor
                      (inventory-leave
                       (merge-inventories cursor from conflict)))
                     (else
                      (inventory-leave
                       (inventory-insert (inventory-open to) from))))))))))


(define-record-type inventory-mapper
  (fields map-leaf map-container))

(define (map-leaf mapper reverse-path)
  ((inventory-mapper-map-leaf mapper) reverse-path))

(define (map-container mapper reverse-path)
  ((inventory-mapper-map-container mapper) reverse-path))

(define (apply-inventory-mapper dest source mapper)
  (loop continue
      ((for from (in-inventory source (result source-result)))
       (with to dest))
    => (values to source-result)
    (let ((name (inventory-name from)))
      (define (move+iterate path)
        #;
        (log/categorizer 'debug (cat "moving item " (dsp-path/reverse r-path)
                                     " to " (dsp-path path)))
        (let ((dest (inventory-leave-n
                     (inventory-update to path from)
                     (length path))))
          (receive (empty? cursor) (inventory-delete from)
            (if empty?
                (values dest (inventory-leave cursor))
                (continue (=> from cursor)
                          (=> to dest))))))
      (define (recurse+iterate dest source sub-mapper depth)
        (receive (dest source)
                 (apply-inventory-mapper dest source sub-mapper)
          (let ((dest (inventory-leave-n dest depth))
                (next (inventory-next source)))
            (if next
                (continue (=> from next)
                          (=> to dest))
                (values dest (inventory-leave source))))))
      (define (handle-container path sub-mapper)
        (if sub-mapper
            (recurse+iterate
             (if (null? path)
                 to
                 (inventory-update to
                                   path
                                   #t
                                   (inventory-data from)))
             from
             sub-mapper
             (length path))
            (move+iterate path)))
      (if (inventory-leaf? from)
          (cond ((map-leaf mapper name)  => move+iterate)
                (else
                 (continue)))
          (receive (path sub-mapper)
                   (map-container mapper name)
            (if path
                (handle-container path sub-mapper)
                (continue)))))))
)

;; Local Variables:
;; scheme-indent-styles: (foof-loop (match 1))
;; End: