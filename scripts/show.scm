;;; show.scm --- Dorodango for Guile

;; Copyright (C) 2011 Free Software Foundation, Inc.
;; Copyright (C) 2009, 2010 Andreas Rottmann <a.rottmann@gmx.at>

;; Author: Andreas Rottmann <a.rottmann@gmx.at>
;; Author: Andy Wingo <wingo@pobox.com>

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

;; This is the command-line interface to dorodango.

;;; Code:

(define-module (scripts show)
  #:use-module (guildhall cli)
  #:use-module (guildhall cli db)
  #:use-module (guildhall ext fmt)
  #:use-module (guildhall ext foof-loop)
  #:use-module (guildhall private utils)
  #:use-module (guildhall database)
  #:use-module (guildhall package)
  #:use-module (guildhall destination fhs)
  #:use-module (guildhall destination)
  #:use-module (guildhall spells pathname)
  #:use-module (guildhall inventory)
  #:use-module (guildhall ui formatters))

(define %summary "Show package information.")
(define %synopsis "show [--bundle=BUNDLE]... PACKAGE...")
(define %help "
  -b, --bundle=BUNDLE  Temporarily add BUNDLE's contents to the package
                       database.

  -c, --config=FILE    Use configuration file FILE, instead of the
                       default.
      --no-config      Do not read a configuration file.
      --help           Print this help message.
      --version        Print version information.
")

(define (search-load-path item)
  %load-path)


(define (dsp-db-item item)
  (dsp-package (database-item-package item)
               (cat "Status: " (database-item-state item) "\n")))

(define (parse-package-string s)
  (cond ((maybe-string->package s "=")
         => (lambda (package)
              (values (package-name package)
                      (package-version package))))
        (else
         (values (string->symbol s) #f))))

(define (find-db-items db packages)
  (loop ((for package (in-list packages))
         (for result
              (appending-reverse
               (call-with-values (lambda () (parse-package-string package))
                 (lambda (name version)
                   (if version
                       (or (and=> (database-lookup db name version) list)
                           '())
                       (database-items db name)))))))
    => (reverse result)))

(define (directory-string db category)
  (directory-namestring
   (destination-pathname
    ((@@ (guildhall database) database-destination) db)
    (make-package 'PKG '((0)))
    category "module.scm")))

(define %mod (current-module))
(define (main . args)
  (define bundles '())
  (call-with-parsed-options/config+db
      %mod args
      (list
       (make-option/arg
        '("bundle" #\b)
        (lambda (arg) (set! bundles (append bundles (list arg))))))
    (lambda (packages config db)
      (database-add-bundles! db bundles)
      (fmt #t (fmt-join dsp-db-item
                        (find-db-items db packages)
                        "\n"))
      (fmt #t (cat "\nDestinations:\n"
                   (fmt-join
                    (lambda (category)
                      (cat " - " (symbol->string category) ": /"
                           (directory-string db category)))
                    '(libraries executables documentation)
                    "\n")
                   "\n"))))
  (exit 0))
