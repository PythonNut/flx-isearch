(require 'flx)
(eval-when-compile
  (progn
    (require 'cl)
    (require 'cl-lib)))

(defgroup flx-isearch nil
  "Flex matching in isearch with flx"
  :prefix "flx-isearch-"
  :group 'isearch
  :link '(url-link :tag "Development and bug reports"
           "https://github.com/PythonNut/flx-isearch")
  :link '(url-link :tag "Wiki"
           "https://github.com/PythonNut/flx-isearch/wiki"))

;;;###autoload
(defcustom flx-isearch-message-prefix "[flx] "
  "Prepended to the isearch prompt when flx searching is activated."
  :type 'string
  :group 'flex-isearch)

;; flx-isearch has to store a lot of state
(defvar flx-search-index 0)

(defvar flx-isearch-index 0)
(defvar flx-isearch-point 0)
(defvar flx-isearch-last-search "")
(defvar flx-isearch-was-wrapped nil)

(defvar flx-isearch-lazy-flag nil)
(defvar flx-isearch-last-lazy-flag nil)
(defvar flx-isearch-lazy-index nil)
(defvar flx-isearch-lazy-point nil)

(defvar flx-isearch-original-search-fun nil)
(defvar flx-isearch-activated nil)


(defun flx-isearch-strip-text-properties(txt)
  (set-text-properties 0 (length txt) nil txt)
  txt)

(defun flx-isearch-collect-symbols ()
  (interactive)
  (let ((coll '()))
    (save-excursion
      (goto-char (point-min))
      (while (forward-thing 'symbol)
        (setq coll (cons `(
                            ,(flx-isearch-strip-text-properties
                               (thing-at-point 'symbol))
                            ,(car (bounds-of-thing-at-point 'symbol)))
                     coll)))
      coll)))

(defun flx-isearch-fuse (pairs)
  (lexical-let ((mapping (make-hash-table
                           :test 'equal
                           :size 1000))
                 (result nil))
    (dolist (elt pairs mapping)
      (puthash (first elt) (cons
                             (second elt)
                             (gethash (first elt) mapping nil))
        mapping))))

(defun hash-table-to-alist (hash-table)
  (lexical-let ((result nil))
    (maphash (lambda (key value)
               (setq result (cons `(,key . ,value) result)))
      hash-table)
    result))

(defun flx-isearch-sort (str symbols &optional cache)
  (sort (cl-remove-if-not
          (lambda (item) (car (flx-score (car item) str cache)))
          symbols)
    (lambda (a b)
      (>
        (or (car (flx-score (car a) str cache)) -1)
        (or (car (flx-score (car b) str cache)) -1)))))

;; and the cache stuff
(defvar flx-isearch-cache-level-1 nil)
(defvar flx-isearch-cache-level-2 nil)
(defvar flx-isearch-cache-level-3 nil)

(defun flx-isearch-heatmap (symbol-name)
  (flx-get-heatmap-str symbol-name))

(defun flx-isearch-make-cache()
  (flx-make-string-cache 'flx-isearch-heatmap))

(defun flx-isearch-initialize-state ()
  (setq
    flx-isearch-cache-level-1 (hash-table-to-alist
                                (flx-isearch-fuse
                                  (flx-isearch-collect-symbols)))
    flx-isearch-cache-level-2 (flx-isearch-make-cache)
    flx-isearch-cache-level-3 nil
    flx-isearch-lazy-flag nil
    flx-isearch-last-lazy-flag nil
    flx-isearch-was-wrapped nil
    flx-isearch-index 0
    flx-isearch-point (point)
    flx-isearch-last-search ""))

(defun flx-isearch-resolve-last-state ()
  (when (and flx-isearch-lazy-flag
          (not flx-isearch-last-lazy-flag))
    (setq
      flx-isearch-lazy-index flx-isearch-index
      flx-isearch-lazy-point flx-isearch-point)
    (setq
      flx-isearch-last-lazy-flag t
      flx-isearch-index 0
      flx-isearch-point (point)))

  (when (and (not flx-isearch-lazy-flag)
          flx-isearch-last-lazy-flag)
    (setq
      flx-isearch-last-lazy-flag nil
      flx-isearch-index flx-isearch-lazy-index
      flx-isearch-point flx-isearch-lazy-point))

  (when (and isearch-wrapped (not flx-isearch-was-wrapped))
    (setq
      flx-isearch-was-wrapped t
      flx-isearch-point (point-min)
      flx-isearch-index 0)))

(defun flx-isearch-compute-matches (string)
  (if (equal string flx-isearch-last-search)
    flx-isearch-cache-level-3
    (progn
      (goto-char flx-isearch-point)
      (setq flx-isearch-index 0
        flx-isearch-last-search string
        flx-isearch-cache-level-3
        (flx-isearch-sort string
          flx-isearch-cache-level-1
          flx-isearch-cache-level-2)))))

(defun flx-search-forward (string &optional bound noerror count)
  (interactive "M")
  (flx-isearch-resolve-last-state)
  (let* ((matches (flx-isearch-compute-matches string))
          (match (elt matches flx-isearch-index)))
    (if (search-forward-regexp
          (concat "\\_<" (car match) "\\_>")
          nil t count)
      (point)
      (progn
        (setq flx-isearch-index (1+ flx-isearch-index))
        (if (>= flx-isearch-index (length matches))
          (if noerror
            nil
            (error "flx forward search failed"))
          (progn
            (goto-char flx-isearch-point)
            (flx-search-forward string bound noerror count)))))))

(defun flx-search-backward (string &optional bound noerror count)
  (interactive "M")
  (flx-isearch-resolve-last-state)
  (let* ((matches (flx-isearch-compute-matches string))
          (match (elt matches flx-isearch-index)))
    (if (search-backward-regexp
          (concat "\\_<" (car match) "\\_>")
          nil t count)
      (point)
      (progn
        (setq flx-isearch-index (1+ flx-isearch-index))
        (if (>= flx-isearch-index (length matches))
          (if noerror
            nil
            (error "flx backward search failed"))
          (progn
            (goto-char flx-isearch-point)
            (flx-search-backward string bound noerror count)))))))

(defadvice isearch-lazy-highlight-search (around flx-isearch-set-lazy-flag)
  (let ((flx-isearch-lazy-flag t))
    ad-do-it))

(defun flx-isearch-search-fun ()
  "Set to `isearch-search-fun-function' when `flx-isearch-mode' is
enabled."
  (cond
    (isearch-word
      (if isearch-forward 'word-search-forward 'word-search-backward))
    (isearch-regexp
      (if isearch-forward 're-search-forward 're-search-backward))
    (flx-isearch-activated
      (if isearch-forward 'flx-search-forward 'flx-search-backward))
    (t
      (if isearch-forward 'search-forward 'search-backward))))

(setq isearch-search-fun-function 'flx-isearch-search-fun)

(defun flx-isearch-activate ()
  (interactive)
  (setq flx-isearch-activated t))

(defun flx-isearch-deactivate ()
  (interactive)
  (setq flx-isearch-activated nil))

(define-minor-mode flx-isearch-mode
  :init-value nil
  :group 'flx-isearch
  (if flx-isearch-mode
    (progn
      (setq flx-isearch-original-search-fun isearch-search-fun-function)
      (setq isearch-search-fun-function 'flx-isearch-search-fun)
      (add-hook 'isearch-mode-end-hook 'flx-isearch-deactivate)
      (add-hook 'isearch-mode-hook 'flx-isearch-initialize-state)
      (ad-enable-advice 'isearch-lazy-highlight-search
        'around 'flx-isearch-set-lazy-flag)
      (ad-activate 'isearch-lazy-highlight-search))
    (progn
      (setq isearch-search-fun-function flx-isearch-original-search-fun)
      (remove-hook 'isearch-mode-end-hook 'flx-isearch-deactivate)
      (remove-hook 'isearch-mode-hook 'flx-isearch-initialize-state)
      (ad-disable-advice 'isearch-lazy-highlight-search
        'around 'flx-isearch-set-lazy-flag)
      (ad-activate 'isearch-lazy-highlight-search))))

(defun flx-isearch-forward (&optional regexp-p no-recursive-edit)
  (interactive "P\np")
  (when (and flx-isearch-mode
          (null regexp-p))
    (flx-isearch-activate))
  (isearch-mode t (not (null regexp-p)) nil (not no-recursive-edit)))

(defun flx-isearch-backward (&optional regexp-p no-recursive-edit)
  (interactive "P\np")
  (when (and flx-isearch-mode
          (null regexp-p))
    (flx-isearch-activate))
  (isearch-mode nil (not (null regexp-p)) nil (not no-recursive-edit)))

(provide 'flx-isearch)
