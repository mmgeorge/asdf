;;;; -------------------------------------------------------------------------
;;;; ASDF-Bundle

(asdf/package:define-package :asdf/bundle
  (:recycle :asdf/bundle :asdf)
  (:use :asdf/common-lisp :asdf/driver :asdf/upgrade
   :asdf/component :asdf/system :asdf/find-system :asdf/find-component :asdf/operation
   :asdf/action :asdf/lisp-action :asdf/plan :asdf/operate)
  (:export
   #:bundle-op #:bundle-op-build-args #:bundle-type
   #:bundle-system #:bundle-pathname-type #:bundlable-file-p #:direct-dependency-files
   #:monolithic-op #:monolithic-bundle-op #:operation-monolithic-p
   #:basic-fasl-op #:prepare-fasl-op #:fasl-op #:load-fasl-op #:monolithic-fasl-op
   #:lib-op #:monolithic-lib-op
   #:dll-op #:monolithic-dll-op
   #:binary-op #:monolithic-binary-op
   #:program-op #:compiled-file #:precompiled-system #:prebuilt-system
   #:user-system-p #:user-system #:trivial-system-p
   #+ecl #:make-build
   #:register-pre-built-system
   #:build-args #:name-suffix #:prologue-code #:epilogue-code #:static-library))
(in-package :asdf/bundle)

(with-upgradability ()
  (defclass bundle-op (operation)
    ((build-args :initarg :args :initform nil :accessor bundle-op-build-args)
     (name-suffix :initarg :name-suffix :initform nil)
     (bundle-type :initform :no-output-file :reader bundle-type)
     #+ecl (lisp-files :initform nil :accessor bundle-op-lisp-files)
     #+mkcl (do-fasb :initarg :do-fasb :initform t :reader bundle-op-do-fasb-p)
     #+mkcl (do-static-library :initarg :do-static-library :initform t :reader bundle-op-do-static-library-p)))

  ;; create a single fasl for the entire library
  (defclass basic-fasl-op (bundle-op basic-compile-op)
    ((bundle-type :initform :fasl)))
  (defclass prepare-fasl-op (sideway-operation)
    ((sideway-operation :initform 'load-fasl-op)))
  (defclass fasl-op (basic-fasl-op selfward-operation)
    ((selfward-operation :initform '(prepare-fasl-op #+ecl lib-op))))
  (defclass load-fasl-op (basic-load-op selfward-operation)
    ((selfward-operation :initform '(prepare-op fasl-op))))

  ;; NB: since the monolithic-op's can't be sideway-operation's,
  ;; if we wanted lib-op, dll-op, binary-op to be sideway-operation's,
  ;; we'd have to have the monolithic-op not inherit from the main op,
  ;; but instead inherit from a basic-FOO-op as with basic-fasl-op above.

  ;; On ECL: compile the system and produce linkable ".a" library for it.
  ;; On others: just compile the system.
  (defclass lib-op (bundle-op basic-compile-op)
    ((bundle-type :initform #+(or ecl mkcl) :lib #-(or ecl mkcl) :no-output-file)))

  (defclass dll-op (bundle-op basic-compile-op)
    ;; Link together all the dynamic library used by this system into a single one.
    ((bundle-type :initform :dll)))

  (defclass binary-op (bundle-op basic-compile-op selfward-operation)
    ;; On ECL: produce lib and fasl for the system.
    ;; On "normal" Lisps: produce just the fasl.
    ((selfward-operation :initform '(lib-op fasl-op))))

  (defclass monolithic-op (operation) ()) ;; operation on a system and its dependencies

  (defclass monolithic-bundle-op (monolithic-op bundle-op)
    ((prologue-code :accessor monolithic-op-prologue-code)
     (epilogue-code :accessor monolithic-op-epilogue-code)))

  (defclass monolithic-binary-op (monolithic-bundle-op basic-compile-op sideway-operation selfward-operation)
    ;; On ECL: produce lib and fasl for combined system and dependencies.
    ;; On "normal" Lisps: produce an image file from system and dependencies.
    ((selfward-operation :initform '(monolithic-fasl-op monolithic-lib-op))))

  ;; Create a single fasl for the system and its dependencies.
  (defclass monolithic-fasl-op (monolithic-bundle-op basic-fasl-op) ())

  (defclass monolithic-lib-op (monolithic-bundle-op basic-compile-op)
    ;; ECL: Create a single linkable library for the system and its dependencies.
    ((bundle-type :initform :lib)))

  (defclass monolithic-dll-op (monolithic-bundle-op basic-compile-op sideway-operation selfward-operation)
    ((bundle-type :initform :dll)
     (selfward-operation :initform 'dll-op)
     (sideway-operation :initform 'dll-op)))

  (defclass program-op (monolithic-bundle-op selfward-operation)
    ;; All: create an executable file from the system and its dependencies
    ((bundle-type :initform :program)
     (selfward-operation :initform #+(or mkcl ecl) 'monolithic-lib-op #-(or mkcl ecl) 'load-op)))

  (defun bundle-pathname-type (bundle-type)
    (etypecase bundle-type
      ((eql :no-output-file) nil) ;; should we error out instead?    
      ((or null string) bundle-type)
      ((eql :fasl) #-(or ecl mkcl) (compile-file-type) #+(or ecl mkcl) "fasb")
      #+ecl
      ((member :binary :dll :lib :static-library :program :object :program)
       (compile-file-type :type bundle-type))
      ((eql :binary) "image")
      ((eql :dll) (cond ((os-unix-p) "so") ((os-windows-p) "dll")))
      ((member :lib :static-library) (cond ((os-unix-p) "a") ((os-windows-p) "lib")))
      ((eql :program) (cond ((os-unix-p) nil) ((os-windows-p) "exe")))))

  (defun bundle-output-files (o c)
    (let ((bundle-type (bundle-type o)))
      (unless (eq bundle-type :no-output-file) ;; NIL already means something regarding type.
        (let ((name (or (component-build-pathname c)
                        (format nil "~A~@[~A~]" (component-name c) (slot-value o 'name-suffix))))
              (type (bundle-pathname-type bundle-type)))
          (values (list (subpathname (component-pathname c) name :type type))
                  (eq (type-of o) (component-build-operation c)))))))

  (defmethod output-files ((o bundle-op) (c system))
    (bundle-output-files o c))

  #-(or ecl mkcl)
  (progn
    (defmethod perform ((o program-op) (c system))
      (let ((output-file (output-file o c)))
        (setf *image-entry-point* (ensure-function (component-entry-point c)))
        (dump-image output-file :executable t)))

    (defmethod perform ((o monolithic-binary-op) (c system))
      (let ((output-file (output-file o c)))
        (dump-image output-file))))

  (defclass compiled-file (file-component)
    ((type :initform #-(or ecl mkcl) (compile-file-type) #+(or ecl mkcl) "fasb")))

  (defclass precompiled-system (system)
    ((build-pathname :initarg :fasl)))

  (defclass prebuilt-system (system)
    ((build-pathname :initarg :static-library :initarg :lib
                     :accessor prebuilt-system-static-library))))


;;;
;;; BUNDLE-OP
;;;
;;; This operation takes all components from one or more systems and
;;; creates a single output file, which may be
;;; a FASL, a statically linked library, a shared library, etc.
;;; The different targets are defined by specialization.
;;;
(with-upgradability ()
  (defun operation-monolithic-p (op)
    (typep op 'monolithic-op))

  (defmethod initialize-instance :after ((instance bundle-op) &rest initargs
                                         &key (name-suffix nil name-suffix-p)
                                         &allow-other-keys)
    (declare (ignorable initargs name-suffix))
    (unless name-suffix-p
      (setf (slot-value instance 'name-suffix)
            (unless (typep instance 'program-op)
              (if (operation-monolithic-p instance) "--all-systems" #-ecl "--system")))) ; . no good for Logical Pathnames
    (when (typep instance 'monolithic-bundle-op)
      (destructuring-bind (&rest original-initargs
                           &key lisp-files prologue-code epilogue-code
                           &allow-other-keys)
          (operation-original-initargs instance)
        (setf (operation-original-initargs instance)
              (remove-plist-keys '(:lisp-files :epilogue-code :prologue-code) original-initargs)
              (monolithic-op-prologue-code instance) prologue-code
              (monolithic-op-epilogue-code instance) epilogue-code)
        #-ecl (assert (null (or lisp-files epilogue-code prologue-code)))
        #+ecl (setf (bundle-op-lisp-files instance) lisp-files)))
    (setf (bundle-op-build-args instance)
          (remove-plist-keys '(:type :monolithic :name-suffix)
                             (operation-original-initargs instance))))

  (defmethod bundle-op-build-args :around ((o lib-op))
    (declare (ignorable o))
    (let ((args (call-next-method)))
      (remf args :ld-flags)
      args))

  (defun bundlable-file-p (pathname)
    (let ((type (pathname-type pathname)))
      (declare (ignorable type))
      (or #+ecl (or (equalp type (compile-file-type :type :object))
                    (equalp type (compile-file-type :type :static-library)))
          #+mkcl (equalp type (compile-file-type :fasl-p nil))
          #+(or allegro clisp clozure cmu lispworks sbcl scl xcl) (equalp type (compile-file-type)))))

  (defgeneric* (trivial-system-p) (component))

  (defun user-system-p (s)
    (and (typep s 'system)
         (not (builtin-system-p s))
         (not (trivial-system-p s)))))

(eval-when (#-lispworks :compile-toplevel :load-toplevel :execute)
  (deftype user-system () '(and system (satisfies user-system-p))))

;;;
;;; First we handle monolithic bundles.
;;; These are standalone systems which contain everything,
;;; including other ASDF systems required by the current one.
;;; A PROGRAM is always monolithic.
;;;
;;; MONOLITHIC SHARED LIBRARIES, PROGRAMS, FASL
;;;
(with-upgradability ()
  (defmethod component-depends-on ((o monolithic-lib-op) (c system))
    (declare (ignorable o))
    `((lib-op ,@(required-components c :other-systems t :component-type 'system
                                       :goal-operation (find-operation o 'load-op)
                                       :keep-operation 'compile-op))
      ,@(call-next-method)))
    

  (defmethod component-depends-on ((o monolithic-fasl-op) (c system))
    (declare (ignorable o))
    `((#-(or ecl mkcl) fasl-op #+(or ecl mkcl) lib-op
         ,@(required-components c :other-systems t :component-type 'system
                                  :goal-operation (find-operation o 'load-fasl-op)
                                  :keep-operation 'fasl-op))
      ,@(call-next-method)))

  (defmethod component-depends-on ((o lib-op) (c system))
    (declare (ignorable o))
    `((compile-op ,@(required-components c :other-systems nil :component-type '(not system)
                                           :goal-operation (find-operation o 'load-op)
                                           :keep-operation 'compile-op))
      ,@(call-next-method)))

  #-ecl
  (defmethod component-depends-on ((o fasl-op) (c system))
    `(,@(component-depends-on (find-operation o 'lib-op) c)
      ,@(call-next-method)))

  (defmethod component-depends-on ((o dll-op) c)
    `(,@(component-depends-on (find-operation o 'lib-op) c)
      ,@(call-next-method)))

  (defmethod component-depends-on :around ((o bundle-op) (c component))
    (declare (ignorable o c))
    (if-let (op (and (eq (type-of o) 'bundle-op) (component-build-operation c)))
      `((,op ,c))
      (call-next-method)))

  (defun direct-dependency-files (o c &key (test 'identity) (key 'output-files) &allow-other-keys)
    ;; This file selects output files from direct dependencies;
    ;; your component-depends-on method better gathered the correct dependencies in the correct order.
    (while-collecting (collect)
      (map-direct-dependencies
       o c #'(lambda (sub-o sub-c)
               (loop :for f :in (funcall key sub-o sub-c)
                     :when (funcall test f) :do (collect f))))))

  (defmethod input-files ((o bundle-op) (c system))
    (direct-dependency-files o c :test 'bundlable-file-p :key 'output-files))

  (defun select-bundle-operation (type &optional monolithic)
    (ecase type
      ((:binary)
       (if monolithic 'monolithic-binary-op 'binary-op))
      ((:dll :shared-library)
       (if monolithic 'monolithic-dll-op 'dll-op))
      ((:lib :static-library)
       (if monolithic 'monolithic-lib-op 'lib-op))
      ((:fasl)
       (if monolithic 'monolithic-fasl-op 'fasl-op))
      ((:program)
       'program-op)))

  (defun make-build (system &rest args &key (monolithic nil) (type :fasl)
                             (move-here nil move-here-p)
                             &allow-other-keys)
    (let* ((operation-name (select-bundle-operation type monolithic))
           (move-here-path (if (and move-here
                                    (typep move-here '(or pathname string)))
                               (pathname move-here)
                               (system-relative-pathname system "asdf-output/")))
           (operation (apply #'operate operation-name
                             system
                             (remove-plist-keys '(:monolithic :type :move-here) args)))
           (system (find-system system))
           (files (and system (output-files operation system))))
      (if (or move-here (and (null move-here-p)
                             (member operation-name '(:program :binary))))
          (loop :with dest-path = (resolve-symlinks* (ensure-directories-exist move-here-path))
                :for f :in files
                :for new-f = (make-pathname :name (pathname-name f)
                                            :type (pathname-type f)
                                            :defaults dest-path)
                :do (rename-file-overwriting-target f new-f)
                :collect new-f)
          files))))

;;;
;;; LOAD-FASL-OP
;;;
;;; This is like ASDF's LOAD-OP, but using monolithic fasl files.
;;;
(with-upgradability ()
  (defmethod component-depends-on ((o load-fasl-op) (c system))
    (declare (ignorable o))
    `((,o ,@(loop :for dep :in (component-sideway-dependencies c)
                  :collect (resolve-dependency-spec c dep)))
      (,(if (user-system-p c) 'fasl-op 'load-op) ,c)
      ,@(call-next-method)))

  (defmethod input-files ((o load-fasl-op) (c system))
    (when (user-system-p c)
      (output-files (find-operation o 'fasl-op) c)))

  (defmethod perform ((o load-fasl-op) c)
    (declare (ignorable o c))
    nil)

  (defmethod perform ((o load-fasl-op) (c system))
    (perform-lisp-load-fasl o c))

  (defmethod mark-operation-done :after ((o load-fasl-op) (c system))
    (mark-operation-done (find-operation o 'load-op) c)))

;;;
;;; PRECOMPILED FILES
;;;
;;; This component can be used to distribute ASDF systems in precompiled form.
;;; Only useful when the dependencies have also been precompiled.
;;;
(with-upgradability ()
  (defmethod trivial-system-p ((s system))
    (every #'(lambda (c) (typep c 'compiled-file)) (component-children s)))

  (defmethod output-files (o (c compiled-file))
    (declare (ignorable o c))
    nil)
  (defmethod input-files (o (c compiled-file))
    (declare (ignorable o))
    (component-pathname c))
  (defmethod perform ((o load-op) (c compiled-file))
    (perform-lisp-load-fasl o c))
  (defmethod perform ((o load-source-op) (c compiled-file))
    (perform (find-operation o 'load-op) c))
  (defmethod perform ((o load-fasl-op) (c compiled-file))
    (perform (find-operation o 'load-op) c))
  (defmethod perform ((o operation) (c compiled-file))
    (declare (ignorable o c))
    nil))

;;;
;;; Pre-built systems
;;;
(with-upgradability ()
  (defmethod trivial-system-p ((s prebuilt-system))
    (declare (ignorable s))
    t)

  (defmethod perform ((o lib-op) (c prebuilt-system))
    (declare (ignorable o c))
    nil)

  (defmethod component-depends-on ((o lib-op) (c prebuilt-system))
    (declare (ignorable o c))
    nil)

  (defmethod component-depends-on ((o monolithic-lib-op) (c prebuilt-system))
    (declare (ignorable o))
    nil))


;;;
;;; PREBUILT SYSTEM CREATOR
;;;
(with-upgradability ()
  (defmethod output-files ((o binary-op) (s system))
    (list (make-pathname :name (component-name s) :type "asd"
                         :defaults (component-pathname s))))

  (defmethod perform ((o binary-op) (s system))
    (let* ((dependencies (component-depends-on o s))
           (fasl (first (apply #'output-files (first dependencies))))
           (library (first (apply #'output-files (second dependencies))))
           (asd (first (output-files o s)))
           (name (pathname-name asd))
           (name-keyword (intern (string name) (find-package :keyword))))
      (with-open-file (s asd :direction :output :if-exists :supersede
                             :if-does-not-exist :create)
        (format s ";;; Prebuilt ASDF definition for system ~A" name)
        (format s ";;; Built for ~A ~A on a ~A/~A ~A"
                (lisp-implementation-type)
                (lisp-implementation-version)
                (software-type)
                (machine-type)
                (software-version))
        (let ((*package* (find-package :keyword)))
          (pprint `(defsystem ,name-keyword
                     :class prebuilt-system
                     :components ((:compiled-file ,(pathname-name fasl)))
                     :lib ,(and library (file-namestring library)))
                  s)))))

  #-(or ecl mkcl)
  (defmethod perform ((o basic-fasl-op) (c system))
    (let* ((input-files (input-files o c))
           (fasl-files (remove (compile-file-type) input-files :key #'pathname-type :test-not #'equalp))
           (non-fasl-files (remove (compile-file-type) input-files :key #'pathname-type :test #'equalp))
           (output-files (output-files o c))
           (output-file (first output-files)))
      (unless input-files (format t "WTF no input-files for ~S on ~S !???" o c))
      (when input-files
        (assert output-files)
        (when non-fasl-files
          (error "On ~A, asdf-bundle can only bundle FASL files, but these were also produced: ~S"
                 (implementation-type) non-fasl-files))
        (when (and (typep o 'monolithic-bundle-op)
                   (or (monolithic-op-prologue-code o) (monolithic-op-epilogue-code o)))
          (error "prologue-code and epilogue-code are not supported on ~A"
                 (implementation-type)))
        (with-staging-pathname (output-file)
          (combine-fasls fasl-files output-file)))))

  (defmethod input-files ((o load-op) (s precompiled-system))
    (declare (ignorable o))
    (bundle-output-files (find-operation o 'fasl-op) s))

  (defmethod perform ((o load-op) (s precompiled-system))
    (perform-lisp-load-fasl o s))

  (defmethod component-depends-on ((o load-fasl-op) (s precompiled-system))
    (declare (ignorable o))
    `((load-op ,s) ,@(call-next-method))))

  #| ;; Example use:
(asdf:defsystem :precompiled-asdf-utils :class asdf::precompiled-system :fasl (asdf:apply-output-translations (asdf:system-relative-pathname :asdf-utils "asdf-utils.system.fasl")))
(asdf:load-system :precompiled-asdf-utils)
|#

#+ecl
(with-upgradability ()
  (defmethod perform ((o bundle-op) (c system))
    (let* ((object-files (input-files o c))
           (output (output-files o c))
           (bundle (first output))
           (kind (bundle-type o)))
      (create-image
       bundle (append object-files (bundle-op-lisp-files o))
       :kind kind
       :entry-point (component-entry-point c)
       :prologue-code
       (when (typep o 'monolithic-bundle-op)
         (monolithic-op-prologue-code o))
       :epilogue-code
       (when (typep o 'monolithic-bundle-op)
         (monolithic-op-epilogue-code o))
       :build-args (bundle-op-build-args o)))))

#+mkcl
(with-upgradability ()
  (defmethod perform ((o lib-op) (s system))
    (apply #'compiler::build-static-library (output-file o c)
           :lisp-object-files (input-files o s) (bundle-op-build-args o)))

  (defmethod perform ((o basic-fasl-op) (s system))
    (apply #'compiler::build-bundle (output-file o c) ;; second???
           :lisp-object-files (input-files o s) (bundle-op-build-args o)))

  (defun bundle-system (system &rest args &key force (verbose t) version &allow-other-keys)
    (declare (ignore force verbose version))
    (apply #'operate 'binary-op system args)))

#+(or ecl mkcl)
(with-upgradability ()
  (defun register-pre-built-system (name)
    (register-system (make-instance 'system :name (coerce-name name) :source-file nil))))

