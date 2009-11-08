;;; doro.sps --- Dorodango package manager

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

;; This is the command-line interface to dorodango.

;;; Code:
#!r6rs

(import (except (rnrs) file-exists? delete-file)
        (only (srfi :1) drop concatenate unfold)
        (srfi :8 receive)
        (only (srfi :13)
              string-null?
              string-prefix?
              string-suffix?
              string-trim-both)
        (srfi :67 compare-procedures)
        (spells alist)
        (spells match)
        (spells fmt)
        (spells foof-loop)
        (spells nested-foof-loop)
        (spells pathname)
        (spells filesys)
        (spells define-values)
        (only (spells misc) and=>)
        (only (spells sysutils) lookup-environment-variable)
        (rename (spells args-fold)
                (option %option))
        (spells logging)
        (spells tracing)
        (only (spells record-types) define-record-type*)
        (dorodango private utils)
        (dorodango package)
        (dorodango database)
        (dorodango destination)
        (dorodango bundle)
        (only (dorodango solver) logger:dorodango.solver)
        (dorodango config)
        (dorodango ui cmdline)
        (dorodango actions))


;;; Command-line processing

(define-record-type* option-info
  (make-option-info %option metavar help)
  ())

(define (option-info-names opt-info)
  (option-names (option-info-%option opt-info)))

(define (%option-proc proc)
  (lambda (option name arg . seeds)
    (apply proc name arg seeds)))

(define (option names arg-info help proc)
  (define (info arg-required? arg-optional? metavar)
    (make-option-info (%option names
                               arg-required?
                               arg-optional?
                               (%option-proc proc))
                      metavar
                      help))
  (match arg-info
    ('#f
     (info #f #f #f))
    ((? symbol? metavar)
     (info #t #f metavar))))

(define (help-%option command)
  (%option
   '("help" #\h) #f #f
   (lambda (option name arg vals)
     (values #t (acons 'run
                       (lambda (vals)
                         (fmt #t (dsp-help command))
                         '())
                       vals)))))

(define (dsp-option-name name)
  (cat (if (string? name) "--" "-") name))

(define (dsp-opt-info/left-side opt-info)
  (cat (fmt-join dsp-option-name (option-info-names opt-info) ", ")
       (cond ((option-info-metavar opt-info)
              => (lambda (metavar)
                   (cat " " (string-upcase (symbol->string metavar)))))
             (else
              ""))))

(define (dsp-help command)
  (let ((synopsis (command-synopsis command)))
    (cat "doro " (car synopsis) "\n"
         (fmt-columns (list "     " (fmt-join/suffix dsp (cdr synopsis) "\n")))
         (apply-cat (command-description command)) "\n"
         "Options:\n"
         (dsp-listing "  " (append
                            (map (lambda (opt-info)
                                   (dsp-opt-info/left-side opt-info))
                                 (command-options command))
                            '("--help"))
                      "  " (append (map option-info-help (command-options command))
                                   '("Show this help and exit"))))))

;; This could use a better name
(define (dsp-listing indent left-items separator right-items)
  (lambda (st)
    (let* ((left-sides
            (map (lambda (left)
                   (fmt #f (cat indent left)))
                 left-items))
           (left-width (fold-left max 0 (map string-length left-sides))))
      ((apply-cat
        (map (lambda (left right)
               (columnar left-width (dsp left)
                         separator
                         (with-width (- 78 left-width) (wrap-lines right))))
             left-sides right-items))
       st))))


;;; Commands

(define %commands '())

(define (command-list)
  (reverse %commands))

(define-record-type* command
  (make-command name description synopsis options handler)
  ())

(define (find-command name)
  (find (lambda (command)
          (eq? name (command-name command)))
        %commands))

(define-syntax define-command
  (syntax-rules (description synopsis options handler)
    ((_ name
        (description description-item ...)
        (synopsis synopsis-item ...)
        (options option-item ...)
        (handler proc))
     (define-values ()
       (set! %commands (cons (make-command 'name
                                           (list description-item ...)
                                           (list synopsis-item ...)
                                           (list option-item ...)
                                           proc)
                             %commands))))))

(define (arg-pusher name)
  (lambda (option-name arg vals)
    (values #f (apush name arg vals))))

(define (arg-setter name)
  (lambda (option-name arg vals)
    (values #f (acons name arg vals))))

(define (value-setter name value)
  (lambda (option-name arg vals)
    (values #f (acons name value vals))))

(define bundle-option
  (option '("bundle" #\b) 'bundle
          "Additionally consider packages from BUNDLE"
          (arg-pusher 'bundles)))

(define no-depends-option
  (option '("no-depends") #f
          "Ignore dependencies"
          (value-setter 'no-depends? #t)))

(define (parse-package-string s)
  (values (string->symbol s) #f)) ;++version

(define (string->package s)
  (make-package (string->symbol s) '())) ;++version

(define (find-db-items db packages)
  (loop ((for package (in-list packages))
         (for result
              (listing
               (receive (name version) (parse-package-string package)
                 (database-lookup db name version)))))
    => (reverse result)))


;;; Querying

(define-command list
  (description "List packages")
  (synopsis "list")
  (options (option '("all") #f
                   "Also show available packages"
                   (value-setter 'all? #t))
           bundle-option)
  (handler
   (lambda (vals)
     (let ((all? (assq-ref vals 'all?))
           (db (config->database (assq-ref vals 'config))))
       (database-add-bundles! db (opt-ref/list vals 'bundles))
       (loop ((for package items (in-database db (sorted-by symbol<?))))
         (cond (all?
                (fmt #t (fmt-join/suffix dsp-db-item/short items "\n")))
               ((find database-item-installed? items)
                => (lambda (installed)
                     (fmt #t (dsp-db-item/short installed) "\n")))))))))

(define-command show
  (description "Show package information")
  (synopsis "show [--bundle BUNDLE]... PACKAGE...")
  (options bundle-option)
  (handler
   (lambda (vals)
     (let ((packages (opt-ref/list vals 'operands))
           (db (config->database (assq-ref vals 'config))))
       (database-add-bundles! db (opt-ref/list vals 'bundles))
       (loop ((for item (in-list (find-db-items db packages))))
         (fmt #t (dsp-db-item item)))))))

(define-command show-bundle
  (description "Show bundle contents")
  (synopsis "show-bundle BUNDLE...")
  (options)
  (handler
   (lambda (vals)
     (loop ((for bundle-location (in-list (opt-ref/list vals 'operands))))
       (let ((bundle (open-input-bundle bundle-location)))
         (fmt #t (dsp-bundle bundle)))))))


;;; Package installation and removal

(define-command update
  (description "Update repository information")
  (synopsis "update")
  (options)
  (handler
   (lambda (vals)
     (let ((db (config->database (assq-ref vals 'config))))
       (database-update! db)
       (close-database db)))))

(define (select-package db package-string)
  (receive (name version) (parse-package-string package-string)
    (let ((item (database-lookup db name version)))
      (cond ((not item)
             (die (cat "could not find any package matching `"
                       package-string "'")))
            (else
             (database-item-package item))))))

(define (install-command vals)
  (let ((bundle-locations (opt-ref/list vals 'bundles))
        (packages (opt-ref/list vals 'operands))
        (no-depends? (assq-ref vals 'no-depends?))
        (db (config->database (assq-ref vals 'config))))
    (database-add-bundles! db bundle-locations)
    (loop ((for package (in-list packages))
           (for to-install (listing (select-package db package))))
      => (cond (no-depends?
                (loop ((for package (in-list to-install)))
                  (database-install! db package)))
               (else
                (apply-actions db to-install '()))))))

(define-command install
  (description "Install new packages")
  (synopsis "install [--bundle BUNDLE]... PACKAGE...")
  (options bundle-option no-depends-option)
  (handler install-command))

(define (remove-command vals)
  (let ((packages (opt-ref/list vals 'operands))
        (no-depends? (assq-ref vals 'no-depends?))
        (db (config->database (assq-ref vals 'config))))
    (cond (no-depends?
           (loop ((for package-name (in-list packages)))
             (unless (database-remove! db (string->symbol package-name))
               (message "Package " package-name " was not installed."))))
          (else
           (loop ((for package-name (in-list packages))
                  (for to-remove (listing (string->symbol package-name))))
             => (apply-actions db '() to-remove))))))

(define-command remove
  (description "Remove packages")
  (synopsis "remove PACKAGE...")
  (options no-depends-option)
  (handler remove-command))


;;; Querying

(define (config-command vals)
  (let* ((config (assq-ref vals 'config))
         (operands (opt-ref/list vals 'operands))
         (n-operands (length operands)))
    (if (null? operands)
        (dsp-config config)
        (case (string->symbol (car operands))
          ((destination)
           (unless (<= 3 n-operands 4)
             (die "`config destination' requires 2 or 3 arguments"))
           (let ((destination (config-item-destination
                               (config-default-item config)))
                 (package (string->package (list-ref operands 1)))
                 (category (string->symbol (list-ref operands 2)))
                 (pathname (if (> n-operands 3)
                               (->pathname (list-ref operands 3))
                               (make-pathname #f '() #f))))
             (for-each
              (lambda (pathname)
                (fmt #t (dsp-pathname pathname) "\n"))
              (destination-pathnames destination package category pathname))))))))

(define (dsp-config config)
  (dsp "Sorry, not yet implemented."))

(define-command config
  (description "Show configuration")
  (synopsis "config destination PACKAGE CATEGORY [FILENAME]")
  (options)
  (handler config-command))


;;; Packaging

(define (create-bundle-command vals)
  (define (read-packages-list pkg-list-files append-version)
    (collect-list (for pathname (in-list pkg-list-files))
      (let ((packages (call-with-input-file (->namestring pathname)
                        read-pkg-list)))
        (if (null? append-version)
            packages
            (map (lambda (package)
                   (package-modify-version
                    package
                    (lambda (version)
                      (append version append-version))))
                 packages)))))
  (define (compute-bundle-name packages)
    (match packages
      (()
       (die "all package lists have been empty."))
      ((package)
       (package-identifier package))
      (_
       (die "multiple packages found and no bundle name specified."))))
  (let ((directories (match (opt-ref/list vals 'operands)
                       (()
                        (list (make-pathname #f '() #f)))
                       (operands
                        (map pathname-as-directory operands))))
        (output-directory (or (and=> (assq-ref vals 'output-directory)
                                     pathname-as-directory)
                              (make-pathname #f '() #f)))
        (output-filename (assq-ref vals 'output-filename))
        (append-version (or (and=> (assq-ref vals 'append-version)
                                   string->package-version)
                            '())))
    (let ((pkg-list-files (find-pkg-list-files directories))
          (need-rewrite? (not (null? append-version))))
      (when (null? pkg-list-files)
        (die (cat "no package lists found in or below "
                  (fmt-join dsp-pathname pkg-list-files ", ")) "."))
      (let* ((packages-list (read-packages-list pkg-list-files append-version))
             (output
              (or output-filename
                  (->namestring
                   (pathname-with-file
                    output-directory
                    (compute-bundle-name (concatenate packages-list)))))))
        (create-bundle output
                       (map (lambda (pathname)
                              (pathname-with-file pathname #f))
                            pkg-list-files)
                       packages-list
                       need-rewrite?)))))

(define (read-pkg-list port)
  (unfold eof-object?
          parse-package-form
          (lambda (seed) (read port))
          (read port)))

(define (find-pkg-list-files directories)
  (define (subdirectory-pkg-list-files directory)
    (loop ((for filename (in-directory directory))
           (let pathname
               (pathname-join directory
                              (make-pathname #f (list filename) "pkg-list.scm")))
           (for result (listing pathname (if (file-exists? pathname)))))
      => result))
  (loop ((for directory (in-list directories))
         (for result
              (appending-reverse
               (let ((pathname (pathname-with-file directory "pkg-list.scm")))
                 (if (file-exists? pathname)
                     (list pathname)
                     (subdirectory-pkg-list-files directory))))))
    => (reverse result)))

(define-command create-bundle
  (description "Create a bundle")
  (synopsis "create-bundle [DIRECTORY...]")
  (options (option '("output" #\o) 'filename
                   "Bundle filename"
                   (arg-setter 'output-filename))
           (option '("directory" #\d) 'directory
                   "Output directory when using implicit filename"
                   (arg-setter 'output-directory))
           (option '("append-version") 'version
                   "Append VERSION to each package's version"
                   (arg-setter 'append-version)))
  (handler create-bundle-command))

(define (scan-bundles-in-directory directory base)
  (let ((directory (pathname-as-directory directory))
        (base (pathname-as-directory base)))
    (define (scan-entry filename)
      (let ((pathname (pathname-with-file directory filename)))
        (cond ((file-directory? pathname)
               (scan-bundles-in-directory pathname
                                          (pathname-with-file base filename)))
              ((and (file-regular? pathname)
                    (string-suffix? ".zip" (file-namestring pathname)))
               (call-with-input-bundle pathname (bundle-options no-inventory)
                 (lambda (bundle)
                   (collect-list ((for package (in-list (bundle-packages bundle))))
                     (cons package (pathname-with-file base filename)))))))))
    (loop ((for filename (in-directory directory))
           (for result (appending-reverse (scan-entry filename))))
      => result)))

(define (scan-bundles-command vals)
  (iterate! (for directory (in-list (opt-ref/list vals 'operands)))
      (for entry (in-list (scan-bundles-in-directory directory directory)))
    (match entry
      ((package . bundle-pathname)
       (fmt #t
            (pretty/unshared
             (package->form (package-with-property
                             package
                             'location
                             (list (pathname->location bundle-pathname))))))))))

(define-command scan-bundles
  (description "Scan one or more directories for bundles")
  (synopsis "scan-bundles DIRECTORY...")
  (options)
  (handler scan-bundles-command))


;;; Entry point

(define (process-command-line command cmd-line seed-vals)
  (define (unrecognized-option option name arg vals)
    (error 'process-command-line "unrecognized option" name))
  (define (process-operand operand vals)
    (apush 'operands operand vals))
  (let ((vals (args-fold* cmd-line
                          (cons (help-%option command)
                                (map option-info-%option
                                     (command-options command)))
                          unrecognized-option
                          process-operand
                          seed-vals)))
    (cond (((or (assq-ref vals 'run)
                (command-handler command))
            vals)
           (exit))
          (else
           (fmt #t "Aborted.\n")
           (exit #f)))))

(define (dsp-usage)
  (cat "dorodango v0.0\n"
       "Usage: doro COMMAND OPTION... ARG...\n"
       "\n"
       (wrap-lines
        "doro is a simple command-line interface for downloading, "
        "installing and inspecting packages containing R6RS libraries.")
       "\n"
       "Commands:\n"
       (dsp-listing "  " (map command-name (command-list))
                    "  " (map (lambda (command)
                                 (apply-cat (command-description command)))
                               (command-list)))
       "\n\n"
       "Use \"doro COMMAND --help\" to get more information about COMMAND.\n"
       (pad/both 72 "This doro has Super Ball Powers.") "\n"))

;; This should be different on non-POSIX systems, I guess
(define (default-config-location)
  (home-pathname '((".config" "dorodango") "config.scm")))

(define (config->database config)
  (let ((default (config-default-item config)))
    (open-database (config-item-database-location default)
                   (config-item-destination default)
                   (config-item-repositories default)
                   (config-item-cache-directory default))))

(define config-option
  (option '("config" #\c) 'config
          (cat "Use configuration file CONFIG"
               " (default: `" (dsp-pathname (default-config-location)) "')")
          (arg-setter 'config)))

(define prefix-option
  (option '("prefix") 'prefix
          (cat "Set installation prefix and database location")
          (arg-setter 'prefix)))

;; TODO: This is a kludge; should add the capabilty to stop on first
;; non-option argument to args-fold*
(define (split-command-line cmd-line)
  (loop continue ((for argument arguments (in-list cmd-line))
                  (for option-arguments (listing-reverse argument))
                  (with option-arg? #f))
    => (values (reverse option-arguments) arguments)
    (cond (option-arg?
           (continue (=> option-arg? #f)))
          ((string-prefix? "-" argument)
           (cond ((member argument '("--destination" "-d"
                                     "--config" "-c"
                                     "--prefix"))
                  (continue (=> option-arg? #t)))
                 (else
                  (continue))))
          (else
           (values (reverse option-arguments) arguments)))))

(define (main-handler vals)
  (define (read-config/default pathname)
    (guard (c ((i/o-file-does-not-exist-error? c)
               (cond (pathname
                      (die (cat "specified config file `"
                                (dsp-pathname pathname) "' does not exist.")))
                     (else (default-config)))))
      (call-with-input-file (->namestring (or pathname (default-config-location)))
        read-config)))
  (let ((operands (opt-ref/list vals 'operands))
        (prefix (assq-ref vals 'prefix)))
    (cond ((null? operands)
           (fmt #t (dsp-usage)))
          ((find-command (string->symbol (car operands)))
           => (lambda (command)
                (let ((config (if prefix
                                  (make-prefix-config prefix '())
                                  (read-config/default (assq-ref vals 'config)))))
                  (process-command-line command
                                        (cdr operands)
                                        `((operands . ())
                                          (config . ,config))))))
          (else
           (error 'main "unknown command" (car operands))))))

(define main-command
  (make-command '%main
                '("Manage packages")
                '("[OPTION...] COMMAND [ARGS...]")
                (list config-option prefix-option)
                main-handler))

(define (make-message-log-handler name-drop)
  (lambda (entry)
    (let ((port (current-output-port))
          (obj (log-entry-object entry))
          (level-name (log-entry-level-name entry))
          (name (drop (log-entry-logger-name entry) name-drop)))
      (fmt port
           (if (memq level-name '(info))
                    fmt-null
                    (cat "doro: " level-name ": "))
           (if (null? name)
                    fmt-null
                    (cat "[" (fmt-join dsp name ".") "] ")))
      (if (procedure? obj)
          (obj port)
          (display obj port))
      (fmt port "\n"))))

(define (main argv)
  (for-each
   (match-lambda
    ((logger . properties)
     (set-logger-properties!
      logger
      properties)))
   `((,logger:dorodango
      (handlers (info ,(make-message-log-handler 1))))
     (,logger:dorodango.solver
      (propagate? #f)
      (handlers (warning ,(make-message-log-handler 1))))))
  (receive (option-arguments arguments) (split-command-line (cdr argv))
    (process-command-line main-command
                          option-arguments
                          `((operands . ,(reverse arguments))))))

(main (command-line))

;; Local Variables:
;; scheme-indent-styles: (foof-loop (match 1) (make-finite-type-vector 3))
;; End:
