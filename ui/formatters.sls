;;; formatters.sls --- formatting combinators

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

(library (dorodango ui formatters)
  (export dsp-solution
          dsp-bundle
          dsp-package
          dsp-package-version)
  (import (rnrs)
          (spells fmt)
          (spells foof-loop)
          (dorodango inventory)
          (dorodango package)
          (dorodango bundle)
          (dorodango solver)
          (prefix (dorodango solver universe)
                  universe-)
          (dorodango solver choice)
          (dorodango database dependencies))

(define (dsp-solution solution)
  (let ((choices (list-sort (lambda (c1 c2)
                              (< (choice-id c1) (choice-id c2)))
                            (choice-set->list (solution-choices solution)))))
    (fmt-join/suffix (lambda (choice)
                       (cat (dsp-dependency (choice-dep choice))
                            "\n -> " (dsp-choice choice)))
                     choices
                     "\n")))

(define (dsp-choice choice)
  (let* ((version (choice-version choice))
         (name (universe-package-name (universe-version-package version))))
    (cond ((universe-version-tag version)
           => (lambda (tag)
                (cat "Installing " name " " (dsp-package-version tag))))
          (else
           (cat "Removing " name)))))

(define (dsp-package-version version)
  (fmt-join (lambda (part)
              (fmt-join dsp part "."))
            version
            "-"))

(define (dsp-dependency dependency)
  (let ((info (universe-dependency-tag dependency)))
    (cat (package->string (dependency-info-package info) " ")
         " depends upon "
         (fmt-join dsp-dependency-choice (dependency-info-choices info) " or "))))

(define (dsp-dependency-choice choice)
  (let ((constraint (dependency-choice-version-constraint choice)))
    (cat (dependency-choice-target choice)
         (if (null-version-constraint? constraint)
             fmt-null
             (cat " " (wrt/unshared (version-constraint->form constraint)))))))

(define (dsp-package pkg)
  (cat "Package: " (package-name pkg) "\n"
       (cat "Version: " (dsp-package-version (package-version pkg)) "\n")
       (cat "Depends: "
            (fmt-join wrt (package-property pkg 'depends '()) ", ") "\n")
       (fmt-join (lambda (category)
                   (let ((inventory (package-category-inventory pkg category)))
                     (if (inventory-empty? inventory)
                         fmt-null
                         (cat "Inventory: " category "\n"
                              (dsp-inventory inventory)))))
                 (package-categories pkg))))

(define (dsp-inventory inventory)
  (define (dsp-node node path)
    (lambda (state)
      (loop next ((for cursor (in-inventory node))
                  (with st state))
        => st
        (let ((path (cons (inventory-name cursor) path)))
          (if (inventory-leaf? cursor)
              (next (=> st ((cat " " (fmt-join dsp (reverse path) "/") "\n")
                            st)))
              (next (=> st ((dsp-node cursor path) st))))))))
  (dsp-node inventory '()))

(define (dsp-bundle bundle)
  (fmt-join dsp-package (bundle-packages bundle) "\n"))

)

;; Local Variables:
;; scheme-indent-styles: ((cases 2))
;; End: