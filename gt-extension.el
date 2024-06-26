;;; gt-extension.el --- Extension components -*- lexical-binding: t -*-

;; Copyright (C) 2024 lorniu <lorniu@gmail.com>
;; Author: lorniu <lorniu@gmail.com>
;; Package-Requires: ((emacs "28.1"))

;; SPDX-License-Identifier: GPL-3.0-or-later

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;; This file is NOT part of GNU Emacs.

;;; Commentary:

;; Some extension components

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'gt-core)
(require 'gt-faces)


;;; [Http Client] request with curl instead of `url.el'

;; implements via package `plz', you should install it before use this

(defclass gt-plz-http-client (gt-http-client)
  ((extra-args
    :initarg :args
    :type list
    :documentation "Extra arguments passed to curl programe.")))

(defvar plz-curl-program)

(declare-function plz "ext:plz.el" t t)
(declare-function plz-error-message "ext:plz.el" t t)
(declare-function plz-error-curl-error "ext:plz.el" t t)
(declare-function plz-error-response "ext:plz.el" t t)
(declare-function plz-response-status "ext:plz.el" t t)
(declare-function plz-response-body "ext:plz.el" t t)

(defvar gt-plz-initialize-error-message
  "\n\nTry to install curl and specify the program like this to solve the problem:\n
  (setq plz-curl-program \"c:/msys64/usr/bin/curl.exe\")\n
Or switch http client to `gt-url-http-client' instead:\n
  (setq gt-default-http-client (gt-url-http-client))")

(cl-defmethod gt-request :before ((_ gt-plz-http-client) &rest _)
  (unless (and (require 'plz nil t) (executable-find plz-curl-program))
    (error "You should have `plz.el' and `curl' installed before using `gt-plz-http-client'")))

(cl-defmethod gt-request ((client gt-plz-http-client) &key url done fail data headers)
  (let ((plz-curl-default-args
         (if (slot-boundp client 'extra-args)
             (append (oref client extra-args) plz-curl-default-args)
           plz-curl-default-args)))
    (plz (if data 'post 'get) url
      :headers (cons `("User-Agent" . ,(or (oref client user-agent) gt-user-agent)) headers)
      :body data
      :as 'string
      :then (lambda (raw) (funcall done raw))
      :else (lambda (err)
              (let ((ret ;; try to compat with error object of url.el, see `url-retrieve' for details
                     (or (plz-error-message err)
                         (when-let (r (plz-error-curl-error err))
                           (list 'curl-error
                                 (concat (format "%s" (or (cdr r) (car r)))
                                         (pcase (car r)
                                           (2 (when (memq system-type '(cygwin windows-nt ms-dos))
                                                gt-plz-initialize-error-message))))))
                         (when-let (r (plz-error-response err))
                           (list 'http (plz-response-status r) (plz-response-body r))))))
                (funcall fail ret))))))

;; Prefer plz/curl as backend

(when (and (null gt-default-http-client)
           (and (require 'plz nil t) (executable-find plz-curl-program)))
  (setq gt-default-http-client (gt-plz-http-client)))


;;; [Render] buffer render

(defclass gt-buffer-render (gt-render)
  ((buffer-name     :initarg :buffer-name     :initform nil)
   (window-config   :initarg :window-config   :initform nil)
   (split-threshold :initarg :split-threshold :initform nil))
  "Popup a new buffer to display the translation result.")

(defcustom gt-buffer-render-follow-p nil
  "Pop to the result buffer instead of just displaying."
  :type 'boolean
  :group 'go-translate)

(defcustom gt-buffer-render-split-width-threshold 80
  "Threshold width of window horizontal split for Buffer-Render."
  :group 'go-translate
  :type '(choice
          (const :tag "Disable" nil)
          (integer :tag "Threshold")))

(defcustom gt-buffer-render-window-config
  '((display-buffer-reuse-window display-buffer-in-direction)
    (direction . right))
  "Window configuration of buffer window of Buffer-Render.

Notice, this can be overrided by `window-config' slot of render instance."
  :type 'sexp
  :group 'go-translate)

(defcustom gt-buffer-render-init-hook nil
  "Hook run after buffer initialization in Buffer-Render."
  :type 'hook
  :group 'go-translate)

(defcustom gt-buffer-render-output-hook nil
  "Hook run after output finished in Buffer-Render."
  :type 'hook
  :group 'go-translate)

(defvar gt-buffer-render-buffer-name "*gt-result*")

(defvar gt-buffer-render-evil-leading-key nil "Leading key for keybinds in evil mode.")

(defvar-local gt-buffer-render-translator nil)
(defvar-local gt-buffer-render-keybinding-messages nil)
(defvar-local gt-buffer-render-local-map nil)

(declare-function evil-define-key* "ext:evil-core.el" t t)

(cl-defmacro gt-buffer-render-key ((key &optional tag test) &rest form)
  (declare (indent 1))
  `(when ,(or test `,test t)
     (let ((fn ,(if (member (car-safe (car form)) '(function lambda))
                    `,(car form)
                  `(lambda () (interactive) ,@form))))
       (if (and (bound-and-true-p evil-mode) (string-prefix-p ,key "<"))
           (evil-define-key* 'normal gt-buffer-render-local-map
                             (kbd (concat gt-buffer-render-evil-leading-key
                                          (if gt-buffer-render-evil-leading-key " ") ,key))
                             fn)
         (define-key gt-buffer-render-local-map (kbd ,key) fn))
       (setq gt-buffer-render-keybinding-messages
             (cl-remove ,key gt-buffer-render-keybinding-messages :key #'car :test #'string=))
       (when ,tag
         (push (cons ,key ,tag) gt-buffer-render-keybinding-messages)))))

(defun gt-buffer-render--refresh ()
  (interactive)
  (oset gt-buffer-render-translator keep t)
  (gt-start gt-buffer-render-translator))

(defun gt-buffer-render--cycle-next (&optional ignore-rules)
  (interactive "P")
  (with-slots (target taker keep) gt-buffer-render-translator
    (if (and (slot-boundp taker 'langs) (gt-functionp (oref taker langs)))
        (user-error "Current taker not support cycle next")
      (let* ((curr gt-last-target)
             (gt-skip-lang-rules-p ignore-rules)
             (gt-ignore-target-history-p t)
             (next (gt-target taker gt-buffer-render-translator 'next)))
        (unless (equal next curr)
          (setf target next keep t)
          (gt-start gt-buffer-render-translator))))))

(defun gt-buffer-render--toggle-polyglot ()
  (interactive)
  (setq gt-polyglot-p (not gt-polyglot-p))
  (with-slots (target keep) gt-buffer-render-translator
    (setf target nil keep t)
    (gt-start gt-buffer-render-translator)))

(defun gt-buffer-render--browser ()
  (interactive)
  (if-let (url (get-char-property (point) 'gt-url))
      (progn (browse-url url)
             (message "Opening %s... Done!" url))
    (message "No url found on current result.")))

(defun gt-buffer-render--delete-cache ()
  (interactive)
  (when-let ((task (get-pos-property (point) 'gt-task))
             (key (gt-cache-key task (or (get-pos-property (point) 'gt-part) 0))))
    (gt-cache-set gt-default-cacher key nil)
    (message "Delete %s from cacher" key)))

(defun gt-buffer-render--keyboard-quit ()
  (interactive)
  (unwind-protect
      (gt-interrupt-speak-process)
    (keyboard-quit)))

(defun gt-buffer-render--show-tips ()
  (interactive)
  (if gt-buffer-render-keybinding-messages
      (message (mapconcat
                (lambda (kd) (concat (propertize (car kd) 'face 'font-lock-keyword-face) ": " (cdr kd)))
                (reverse gt-buffer-render-keybinding-messages) " "))
    (message "No any help tips found")))

(defun gt-buffer-render--toggle-readonly ()
  (interactive)
  (read-only-mode -1)
  (use-local-map nil)
  (local-set-key (kbd "C-x C-q")
                 (lambda ()
                   (interactive)
                   (read-only-mode 1)
                   (use-local-map gt-buffer-render-local-map))))

(defvar gt-buffer-render-source-text-limit 200
  "Fold some of the source text if it's too long.
This can be a number as visible length or a function with source text
as argument that return a length.")

(defun gt-buffer-render--format-source-text (text)
  "Propertize and insert the source TEXT into render buffer."
  (with-temp-buffer
    (setq text (string-trim text "\n+"))
    (let ((beg (point)) end
          (limit (if (functionp gt-buffer-render-source-text-limit)
                     (funcall gt-buffer-render-source-text-limit text)
                   gt-buffer-render-source-text-limit)))
      (insert (substring-no-properties text))
      (when (and limit (> (- (setq end (point)) beg) limit))
        (save-excursion
          (goto-char (+ beg limit))
          (when (numberp gt-buffer-render-source-text-limit)
            (if (< (- (save-excursion (skip-syntax-forward "w") (point)) (point)) 5)
                (skip-syntax-forward "w")
              (if (< (- (point) (save-excursion (skip-syntax-backward "w") (point))) 5)
                  (skip-syntax-backward "w"))))
          (let ((ov (make-overlay (point) end nil t nil)))
            (cl-flet ((show () (interactive) (mapc (lambda (ov) (delete-overlay ov)) (overlays-at (point)))))
              (overlay-put ov 'display "...")
              (overlay-put ov 'keymap (gt-simple-keymap [return] #'show [mouse-1] #'show))
              (overlay-put ov 'pointer 'hand)
              (overlay-put ov 'help-echo "Click to unfold the text")))))
      (put-text-property beg end 'face 'gt-buffer-render-source-face)
      (insert "\n\n"))
    (buffer-string)))

(defun gt-buffer-render-init (buffer render translator)
  "Init BUFFER for RENDER of TRANSLATOR."
  (with-current-buffer buffer
    (with-slots (text tasks engines) translator
      ;; setup
      (deactivate-mark)
      (visual-line-mode -1)
      (font-lock-mode 1)
      (setq-local cursor-type 'hbar)
      (setq-local cursor-in-non-selected-windows nil)
      (setq-local gt-buffer-render-translator translator)
      ;; headline
      (let ((engines (cl-delete-duplicates (mapcar (lambda (task) (oref task engine)) tasks))))
        (gt-header render translator (unless (cdr engines) (oref (car engines) tag))))
      ;; content
      (let ((inhibit-read-only t)
            (ret (gt-extract render translator)))
        (erase-buffer)
        (newline)
        (save-excursion
          (unless (cdr text) ; single part
            (let ((c (gt-buffer-render--format-source-text (car text))))
              (insert (if (cdr tasks) c (propertize c 'gt-task (car tasks))))))
          (cl-loop for c in text
                   for i from 0
                   if (cdr text) do (insert (gt-buffer-render--format-source-text c)) ; multi parts
                   do (cl-loop for tr in ret
                               for res = (propertize "Loading..."
                                                     'face 'gt-buffer-render-loading-face
                                                     'gt-result t)
                               for (prefix task) = (gt-plist-let tr (list .prefix .task))
                               for output = (propertize (concat prefix res "\n\n") 'gt-task task 'gt-part i)
                               do (insert output)))))
      ;; keybinds
      (setq gt-buffer-render-local-map (make-sparse-keymap))
      (use-local-map gt-buffer-render-local-map)
      (gt-keybinds render translator)
      ;; state
      (read-only-mode 1)
      (if-let (w (get-buffer-window nil t)) (set-window-point w  (point)))
      ;; execute the hook if exists
      (run-hooks 'gt-buffer-render-init-hook))))

(defun gt-buffer-render-output (buffer render translator)
  "Output TRANSLATOR's retult to BUFFER for RENDER."
  (with-current-buffer buffer
    (with-slots (text tasks) translator
      (let ((inhibit-read-only t)
            (ret (gt-extract render translator)) bds prop)
        (save-excursion
          ;; collect positions
          (goto-char (point-min))
          (while (setq prop (text-property-search-forward 'gt-result t t))
            (push (cons (set-marker (make-marker) (prop-match-beginning prop))
                        (set-marker (make-marker) (prop-match-end prop)))
                  bds))
          (setq bds (nreverse bds))
          (goto-char (point-min))
          ;; delete source if necessary
          (when (and (not (cdr ret))
                     (get-pos-property 1 'gt-mark (car (gt-ensure-list (plist-get (car ret) :result)))))
            (skip-chars-forward "\n")
            (delete-region (point) (progn (end-of-line) (skip-chars-forward "\n") (point))))
          ;; output results in bounds
          (cl-loop for _ in text
                   for i from 0
                   do (cl-loop for tr in ret
                               for (beg . end) = (pop bds)
                               for (res state task) = (gt-plist-let tr (list .result .state .task))
                               do (goto-char beg)
                               do (when (and (cl-plusp state) (null (get-char-property beg 'gt-done)))
                                    (delete-region beg end)
                                    (insert (propertize (if (consp res) (nth i res) res)
                                                        'gt-result t 'gt-done t
                                                        'gt-task task
                                                        'gt-part i))))))))
    ;; update states
    (set-buffer-modified-p nil)
    ;; execute the hook if exists
    (run-hooks 'gt-buffer-render-output-hook)))

(cl-defmethod gt-header ((_ gt-buffer-render) translator &optional tag)
  "Set head line format for Buffer Render of TRANSLATOR.
TAG is extra message show in the middle if not nil."
  (with-slots (target) translator
    (let ((line (append
                 '(" ")
                 (when-let (src (car target))
                   (list
                    "[" (propertize (format "%s" src) 'face 'gt-buffer-render-header-lang-face) "]"
                    (if tag (concat " ― " (propertize (format "%s" tag) 'face 'gt-buffer-render-header-desc-face)) "")
                    " → "))
                 (list
                  "["
                  (mapconcat (lambda (s) (propertize (format "%s" s) 'face 'gt-buffer-render-header-lang-face)) (cdr target) ", ")
                  "]"
                  (when (and gt-buffer-render-keybinding-messages (not (bound-and-true-p evil-mode)))
                    (concat "    (" (propertize "?" 'face 'font-lock-type-face) " for tips)"))))))
      (setq header-line-format line))))

(cl-defmethod gt-keybinds ((_ gt-buffer-render) _translator)
  "Define keybinds for `gt-buffer-render-local-map'."
  (gt-buffer-render-key ("t" "Cycle Next")        #'gt-buffer-render--cycle-next)
  (gt-buffer-render-key ("T" "Toggle Polyglot")   #'gt-buffer-render--toggle-polyglot)
  (gt-buffer-render-key ("y" "TTS")               #'gt-do-speak)
  (gt-buffer-render-key ("O" "Browser")           #'gt-buffer-render--browser)
  (gt-buffer-render-key ("c" "Del Cache")         #'gt-buffer-render--delete-cache)
  (gt-buffer-render-key ("C")                     #'gt-purge-cache)
  (gt-buffer-render-key ("g" "Refresh")           #'gt-buffer-render--refresh)
  (gt-buffer-render-key ("n")                     #'next-line)
  (gt-buffer-render-key ("p")                     #'previous-line)
  (gt-buffer-render-key ("h")                     #'backward-char)
  (gt-buffer-render-key ("j")                     #'next-line)
  (gt-buffer-render-key ("k")                     #'previous-line)
  (gt-buffer-render-key ("l")                     #'forward-char)
  (gt-buffer-render-key ("q" "Quit")              #'kill-buffer-and-window)
  (gt-buffer-render-key ("C-g")                   #'gt-buffer-render--keyboard-quit)
  (gt-buffer-render-key ("C-x C-q")               #'gt-buffer-render--toggle-readonly)
  (gt-buffer-render-key ("?")                     #'gt-buffer-render--show-tips))

(cl-defmethod gt-extract :around ((render gt-buffer-render) translator)
  (cl-loop with mpp = (cdr (oref translator text))
           for tr in (cl-call-next-method render translator)
           for (prefix result state) = (gt-plist-let tr (list .prefix (format "%s" .result) .state))
           if (and prefix (or (not (slot-boundp render 'prefix)) (eq (oref render prefix) t)))
           do (plist-put tr :prefix
                         (concat (propertize (concat prefix (unless mpp "\n"))
                                             'face (if mpp 'gt-buffer-render-inline-prefix-face 'gt-buffer-render-block-prefix-face))
                                 "\n"))
           if (= 1 state) do (plist-put tr :result (propertize result 'face 'gt-buffer-render-error-face))
           collect tr))

(cl-defmethod gt-init ((render gt-buffer-render) translator)
  (with-slots (buffer-name split-threshold window-config) render
    (let ((buf (get-buffer-create (or buffer-name gt-buffer-render-buffer-name)))
          (split-width-threshold (or split-threshold gt-buffer-render-split-width-threshold split-width-threshold)))
      (gt-buffer-render-init buf render translator)
      (display-buffer buf (or window-config gt-buffer-render-window-config)))))

(cl-defmethod gt-output ((render gt-buffer-render) translator)
  (when-let (buf (get-buffer (or (oref render buffer-name) gt-buffer-render-buffer-name)))
    (gt-buffer-render-output buf render translator)
    (when (= (oref translator state) 3)
      (if gt-buffer-render-follow-p
          (pop-to-buffer buf)
        (display-buffer buf)))))

(cl-defmethod gt-output :after ((_ gt-buffer-render) translator)
  (when (= (oref translator state) 3) (message "")))


;;; [Render] Child-Frame Render (Popup Mode)
;; implements via package Posframe, you should install it before use this

(defclass gt-posframe-pop-render (gt-buffer-render)
  ((width       :initarg :width        :initform 100)
   (height      :initarg :height       :initform 15)
   (forecolor   :initarg :forecolor    :initform nil)
   (backcolor   :initarg :backcolor    :initform nil)
   (padding     :initarg :padding      :initform 12))
  "Pop up a childframe to show the result.
The frame will disappear when do do anything but focus in it.
Manually close the frame with `q'.")

(defvar gt-posframe-pop-render-buffer " *GT-Pop-Posframe*")
(defvar gt-posframe-pop-render-timeout 30)
(defvar gt-posframe-pop-render-poshandler nil)

(declare-function posframe-show "ext:posframe.el" t t)
(declare-function posframe-delete "ext:posframe.el" t t)
(declare-function posframe-hide "ext:posframe.el" t t)
(declare-function posframe-refresh "ext:posframe.el" t t)
(declare-function posframe-poshandler-frame-top-right-corner "ext:posframe.el" t t)

(defun gt-posframe-render-auto-close-handler ()
  "Close the pop-up posframe window."
  (interactive)
  (unless (or (and gt-current-command
                   (member this-command (list gt-current-command #'exit-minibuffer)))
              (and gt-posframe-pop-render-buffer
                   (string= (buffer-name) gt-posframe-pop-render-buffer)))
    (ignore-errors (posframe-delete gt-posframe-pop-render-buffer))
    (remove-hook 'post-command-hook #'gt-posframe-render-auto-close-handler)))

(cl-defmethod gt-init :before ((_ gt-posframe-pop-render) _)
  (unless (require 'posframe nil t)
    (user-error "To use `gt-posframe-render', you should install and load package `posframe' first")))

(cl-defmethod gt-init ((render gt-posframe-pop-render) translator)
  (with-slots (width height forecolor backcolor padding) render
    (let ((inhibit-read-only t)
          (buf gt-posframe-pop-render-buffer))
      ;; create
      (unless (buffer-live-p (get-buffer buf))
        (posframe-show buf
                       :string "Loading..."
                       :timeout gt-posframe-pop-render-timeout
                       :max-width width
                       :max-height height
                       :foreground-color (or forecolor gt-pop-posframe-forecolor)
                       :background-color (or backcolor gt-pop-posframe-backcolor)
                       :internal-border-width padding
                       :internal-border-color (or backcolor gt-pop-posframe-backcolor)
                       :accept-focus t
                       :position (point)
                       :poshandler gt-posframe-pop-render-poshandler))
      ;; render
      (gt-buffer-render-init buf render translator)
      (posframe-refresh buf)
      ;; setup
      (with-current-buffer buf
        (gt-buffer-render-key ("q" "Close") (posframe-delete buf))))))

(cl-defmethod gt-output ((render gt-posframe-pop-render) translator)
  (when-let (buf (get-buffer gt-posframe-pop-render-buffer))
    (gt-buffer-render-output buf render translator)
    (posframe-refresh buf)
    (add-hook 'post-command-hook #'gt-posframe-render-auto-close-handler)))


;;; [Render] Child-Frame Render (Pin Mode)

(defclass gt-posframe-pin-render (gt-posframe-pop-render)
  ((width       :initarg :width        :initform 60)
   (height      :initarg :height       :initform 20)
   (padding     :initarg :padding      :initform 8)
   (bd-width    :initarg :bd-width     :initform 1)
   (bd-color    :initarg :bd-color     :initform nil)
   (backcolor   :initarg :backcolor    :initform nil)
   (fri-color   :initarg :fringe-color :initform nil)
   (position    :initarg :position     :initform nil))
  "Pin the childframe in a fixed position to display the translate result.
The childframe will not close, until you kill it with `q'.
Other operations in the childframe buffer, just like in 'gt-buffer-render'.")

(defvar gt-posframe-pin-render-buffer " *GT-Pin-Posframe*")
(defvar gt-posframe-pin-render-frame nil)
(defvar gt-posframe-pin-render-poshandler #'posframe-poshandler-frame-top-right-corner)

(cl-defmethod gt-init ((render gt-posframe-pin-render) translator)
  (if (and (get-buffer gt-posframe-pin-render-buffer) gt-posframe-pin-render-frame)
      (make-frame-visible gt-posframe-pin-render-frame)
    (with-slots (width height min-width min-height bd-width forecolor backcolor bd-color padding position) render
      (setq gt-posframe-pin-render-frame
            (let ((inhibit-read-only t))
              (posframe-show gt-posframe-pin-render-buffer
                             :string "\nLoading..."
                             :width width
                             :height height
                             :min-width width
                             :min-height height
                             :foreground-color (or forecolor gt-pin-posframe-forecolor)
                             :background-color (or backcolor gt-pin-posframe-backcolor)
                             :internal-border-width bd-width
                             :border-color (or bd-color gt-pin-posframe-bdcolor)
                             :left-fringe padding
                             :right-fringe padding
                             :refresh nil
                             :accept-focus t
                             :respect-header-line t
                             :position position
                             :poshandler (unless position gt-posframe-pin-render-poshandler)))))
    (set-frame-parameter gt-posframe-pin-render-frame 'drag-internal-border t)
    (set-frame-parameter gt-posframe-pin-render-frame 'drag-with-header-line t)
    (when-let (color (or (oref render fri-color) gt-pin-posframe-fringe-color))
      (set-face-background 'fringe color  gt-posframe-pin-render-frame)))
  ;; render
  (gt-buffer-render-init gt-posframe-pin-render-buffer render translator)
  ;; setup
  (with-current-buffer gt-posframe-pin-render-buffer
    (gt-buffer-render-key ("q" "Close") (posframe-hide gt-posframe-pin-render-buffer))))

(cl-defmethod gt-output ((render gt-posframe-pin-render) translator)
  (gt-buffer-render-output gt-posframe-pin-render-buffer render translator))


;;; [Render] kill-ring render

(defclass gt-kill-ring-render (gt-render) ()
  :documentation "Used to save the translate result into kill ring.")

(cl-defmethod gt-output ((render gt-kill-ring-render) translator)
  (deactivate-mark)
  (when (= (oref translator state) 3)
    (let ((ret (gt-extract render translator)))
      (when-let (err (cl-find-if (lambda (r) (<= (plist-get r :state) 1)) ret))
        (kill-new "")
        (error "%s" (plist-get err :result)))
      (kill-new (mapconcat (lambda (r) (string-join (plist-get r :result) "\n")) ret "\n\n"))
      (message "Result already in the kill ring."))))


;;; [Render] insert render

(defclass gt-insert-render (gt-render)
  ((type
    :initarg :type
    :initform 'after
    :type (or (member after replace) boolean)
    :documentation "How to insert the result.")
   (rfmt
    :initarg :rfmt
    :initform nil
    :documentation "Used to format the result string for insertion.
See `gt-insert-render-format' for details.")
   (sface
    :initarg :sface
    :initform nil
    :documentation "The propertize face of the source text after translation.
If this is nil then do nothing, if this is a face or a function return a face,
just propertize the source text with the face.")
   (rface
    :initarg :rface
    :initform nil
    :documentation "Result face.")))

(defcustom gt-insert-render-type 'after
  "Where to insert the result in Insert-Render.

If this is `replace', insert the result by taking place the source text,
otherwise, insert after the source text.

The value can be overrided by `type' slot of render."
  :type '(choice (const :tag "Repace" replace)
                 (other :tag "Insert after" after))
  :group 'go-translate)

(defcustom gt-insert-render-output-hook nil
  "Hook run after output finished in Insert-Render.
With current translator as the only argument."
  :type 'hook
  :group 'go-translate)

(defun gt-insert-render-format (render src res)
  "Format RES for insert RENDER.

SRC is the source text, RES is list extracted from translate task.

Join them to a string, format or pretty it, at last return it as the result that
used to insert.


If slot `rfmt' is a string contains `%s', format every part of results with
function `format' and join them.

   (gt-insert-render :rfmt \" <%s>\" :rface `font-lock-warning-face)

If `rfmt' is a function with solo argument, apply the function on every part of
results and join them. If with two arguments, pass source text as the first
argument. If four arguments, then chain the formatting task to the function.

   (gt-insert-render :rfmt (lambda (w) (format \" [%s]\"))
                     :rface `font-lock-warning-face)

   (gt-insert-render :rfmt (lambda (s w)
                             (if (length< s 3)
                               (format \"\\n- %s\" w)
                              (propertize w `face `font-lock-warning-face))))

Otherwise, join the results use the default logic."
  (with-slots (type rfmt rface) render
    (cond
     ((stringp rfmt)
      (mapconcat (lambda (r) (gt-face-lazy (format rfmt r) (gt-ensure-plain rface r))) res "\n"))
     ((functionp rfmt)
      (let ((n (cdr (func-arity rfmt))))
        (if (<= n 2)
            (mapconcat (lambda (r)
                         (let ((ret (or (if (= n 2) (funcall rfmt src r) (funcall rfmt r)) r)))
                           (gt-face-lazy ret (gt-ensure-plain rface r))))
                       res "\n")
          (funcall rfmt render src res))))
     (t (setq res (string-join res "\n"))
        ;; when multiple lines or at the end of line, will insert in a new line
        (when (eq type 'after)
          (setq res (concat (if (or (string-match-p "\n" res) (and (not (gt-word-p nil src)) (eolp))) "\n" " ") res)))
        (gt-face-lazy res rface)))))

(cl-defmethod gt-init ((render gt-insert-render) translator)
  (with-slots (bounds state) translator
    (unless bounds
      (error "%s only works for buffer bounds, abort" (eieio-object-class render)))
    (unless (buffer-live-p (car bounds))
      (error "Source buffer is unavailable, abort"))
    (when (with-current-buffer (car bounds) buffer-read-only)
      (error "Source buffer is readonly, can not insert"))))

(cl-defmethod gt-output ((render gt-insert-render) translator)
  (with-slots (bounds state) translator
    (when (= 3 state)
      (let ((ret (gt-extract render translator)))
        (when-let (err (cl-find-if (lambda (tr) (<= (plist-get tr :state) 1)) ret))
          (user-error "Error in translation, %s" (plist-get err :result)))
        (with-current-buffer (car bounds)
          (save-excursion
            (with-slots (rfmt sface) render
              (cl-loop with bds = (mapcar (lambda (bd)
                                            (cons (set-marker (make-marker) (car bd))
                                                  (set-marker (make-marker) (cdr bd))))
                                          (cdr bounds))
                       with type = (let ((type (or (oref render type) gt-insert-render-type))
                                         (types '(after replace)))
                                     (if (member type types) type
                                       (intern (completing-read "Insert text as: " types nil t))))
                       with hash = (when (and (eq type 'replace) (not (buffer-modified-p)))
                                     (buffer-hash))
                       for (beg . end) in bds
                       for i from 0
                       for src = (buffer-substring beg end)
                       for res = (mapcar (lambda (tr) (nth i (plist-get tr :result))) ret)
                       for fres = (progn (goto-char end) (gt-insert-render-format render src res))
                       do (progn (if (eq type 'replace)
                                     (delete-region beg end)
                                   (when-let (face (and (eq type 'after) (gt-ensure-plain sface src)))
                                     (delete-region beg end)
                                     (insert (propertize src 'face face))))
                                 (insert (propertize fres 'type 'gt-insert-result))
                                 (if (= (length bds) (+ i 1)) (push-mark)))
                       finally (when (and hash (equal hash (buffer-hash)))
                                 (set-buffer-modified-p nil)))
              (deactivate-mark)
              (run-hook-with-args 'gt-insert-render-output-hook translator)
              (message "ok."))))))))


;;; [Render] Render with Overlay

(defclass gt-overlay-render (gt-render)
  ((type
    :initarg :type
    :initform 'after
    :type (or (member after replace help-echo before) boolean)
    :documentation "How to display the result.")
   (rfmt
    :initarg :rfmt
    :initform nil
    :documentation
    "Used to format the translation result to fit the overlay display.
See `gt-overlay-render-format' for details.")
   (sface
    :initarg :sface
    :initform 'gt-overlay-source-face
    :documentation "The propertize face of the source text after translation.
If this is nil then do nothing, if this is a face or a function return a face,
just propertize the source text with the face.")
   (rface
    :initarg :rface
    :initform 'gt-overlay-result-face
    :documentation "Result face.")
   (rdisp
    :initarg :rdisp
    :initform nil
    :documentation "Same as rface but used in `display' property.")
   (pface
    :initarg :pface
    :initform 'gt-overlay-prefix-face
    :documentation "Prefix face.")
   (pdisp
    :initarg :pdisp
    :initform nil
    :documentation "Same as pface but used in `display' property.")))

(defcustom gt-overlay-render-type 'after
  "How to display result in Overlay-Render.

If this is `help-echo', display with help echo, if this is `replace', display
by covering the source text, otherwise, display before or after the source text.

The value can be overrided by `type' slot of render."
  :type '(choice (const :tag "Repace" replace)
                 (const :tag "Help Echo" help-echo)
                 (const :tag "After" after)
                 (other :tag "Before" before))
  :group 'go-translate)

(defvar gt-overlay-render-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "<mouse-1>") #'gt-delete-render-overlays)
    (define-key map (kbd "<mouse-3>") #'gt-overlay-render-save-to-kill-ring)
    map)
  "Keymap used in overlay render.")

(defun gt-overlay-render-get-overlays (beg &optional end)
  "Return overlays made by Overlay-Render in the region from BEG to END.
If END is nil, return the overlays at BEG."
  (cl-remove-if-not (lambda (ov) (overlay-get ov 'gt))
                    (if end
                        (save-excursion
                          (goto-char beg)
                          (ignore-errors (forward-same-syntax -1))
                          (setq beg (point))
                          (goto-char end)
                          (ignore-errors (forward-same-syntax))
                          (overlays-in beg (point)))
                      (overlays-at beg))))

(defun gt-delete-render-overlays (beg &optional end)
  "Delete overlays made by Overlay-Render in the region from BEG to END.
If called interactively, delete overlays around point or in region. With
`current-prefix-arg' non nil, delete all overlays in the buffer."
  (interactive (cond (current-prefix-arg (list (point-min) (point-max)))
                     ((use-region-p) (list (region-beginning) (region-end)))
                     (t (list (point) nil))))
  (mapc #'delete-overlay (gt-overlay-render-get-overlays beg end)))

(defun gt-overlay-render-save-to-kill-ring ()
  "Copy translate content at point to kill ring for Overlay-Render."
  (interactive)
  (if-let* ((ov (car (gt-overlay-render-get-overlays (point))))
            (rs (overlay-get ov 'gt)))
      (progn (kill-new (string-trim rs))
             (message "Result already in the kill ring."))
    (user-error "No translate overlay found at point")))

(defun gt-overlay-render-format (render src res prefix)
  "Format RES for overlay RENDER.

SRC is the source text, RES and PREFIX are list extracted from translate task.

Join them to a string, format or pretty it, at last return it as the result that
used to display.

If slot `rfmt' is a string contains `%s', format every part of results with
function `format' and join them.

   (gt-overlay-render :rfmt \" <%s>\" :rface `font-lock-warning-face)

If `rfmt' is a function with solo argument, apply the function on every part of
results and join them. If with two arguments, pass source text as the first
argument. If four arguments, then chain the formatting task to the function.

   (gt-overlay-render :rfmt (lambda (w) (format \" [%s]\"))
                      :rface `font-lock-warning-face)

   (gt-overlay-render :rfmt (lambda (s w)
                              (if (length< s 3)
                                (format \"\\n- %s\")
                               (propertize w `face `font-lock-warning-face))))

Otherwise, join the results use the default logic."
  (with-slots (type rfmt rface rdisp pface pdisp) render
    (cond
     ((stringp rfmt)
      (mapconcat (lambda (r) (gt-face-lazy (format rfmt r)
                                           (gt-ensure-plain rface r)
                                           (gt-ensure-plain rdisp r)))
                 res "\n"))
     ((functionp rfmt)
      (let ((n (cdr (func-arity rfmt))))
        (if (<= n 2)
            (mapconcat (lambda (r)
                         (let ((ret (or (if (= n 2) (funcall rfmt src r) (funcall rfmt r)) r)))
                           (gt-face-lazy ret (gt-ensure-plain rface r) (gt-ensure-plain rdisp r))))
                       res "\n")
          (funcall rfmt render src res prefix))))
     (t (cl-loop for r in res for p in prefix
                 for pr = (gt-face-lazy
                           (concat (if (and (eq type 'after) (and (not (gt-word-p nil src)) (eolp))) "\n") r)
                           (gt-ensure-plain rface r)
                           (gt-ensure-plain rdisp r))
                 for pp = (if p (concat " " (gt-face-lazy p (gt-ensure-plain pface p) (gt-ensure-plain pdisp p))))
                 collect (concat (if (eq type 'after) " ") pr pp) into ret
                 finally (return (string-join ret "\n")))))))

(cl-defmethod gt-init ((render gt-overlay-render) translator)
  (with-slots (bounds state) translator
    (unless bounds
      (error "%s only works for buffer bounds, abort" (eieio-object-class render)))
    (unless (buffer-live-p (car bounds))
      (error "Source buffer is unavailable, abort"))))

(cl-defmethod gt-output ((render gt-overlay-render) translator)
  (with-slots (bounds state) translator
    (when (= 3 state)
      (let ((ret (gt-extract render translator)))
        (when-let (err (cl-find-if (lambda (tr) (<= (plist-get tr :state) 1)) ret))
          (user-error "Error in translation, %s" (plist-get err :result)))
        (with-current-buffer (car bounds)
          (cl-loop with type = (let ((type (or (oref render type) gt-overlay-render-type))
                                     (types '(help-echo replace after before)))
                                 (if (memq type types) type
                                   (intern (completing-read "Display with overlay as: " types nil t))))
                   for (beg . end) in (cdr bounds)
                   for i from 0
                   do (gt-delete-render-overlays beg end)
                   for src = (buffer-substring beg end)
                   do (goto-char end)
                   for fres = (gt-overlay-render-format
                               render src
                               (mapcar (lambda (tr) (nth i (plist-get tr :result))) ret)
                               (mapcar (lambda (tr) (plist-get tr :prefix)) ret))
                   for ov = (make-overlay beg end nil t)
                   do (let* ((sface (oref render sface))
                             (sface (unless (eq type 'replace) (gt-ensure-plain sface src))))
                        (pcase type
                          ('help-echo (overlay-put ov 'help-echo fres))
                          ('after (overlay-put ov 'after-string fres))
                          ('before (overlay-put ov 'before-string fres)))
                        (overlay-put ov 'gt fres)
                        (overlay-put ov 'evaporate t)
                        (overlay-put ov 'pointer 'arrow)
                        (overlay-put ov 'modification-hooks `((lambda (o &rest _) (delete-overlay o))))
                        (overlay-put ov 'keymap gt-overlay-render-map)
                        (if (eq type 'replace)
                            (progn (overlay-put ov 'display fres)
                                   (overlay-put ov 'help-echo src))
                          (if sface (overlay-put ov 'face sface)))))
          (deactivate-mark)
          (message "ok."))))))


;;; [Render] Alert Render

(defclass gt-alert-render (gt-render) ()
  :documentation "Output results as system notification.
It depends on the `alert' package.")

(defvar gt-alert-render-args '(:timeout 10))

(declare-function alert "ext:alert.el" t t)

(cl-defmethod gt-init ((_ gt-alert-render) _)
  (unless (require 'alert nil t)
    (user-error "To use `gt-alert-render', you should install and load package `alert' first")))

(cl-defmethod gt-output ((render gt-alert-render) translator)
  (when (= (oref translator state) 3)
    (let ((ret (gt-extract render translator)) lst)
      ;; format
      (dolist (tr ret)
        (let ((prefix (if (cdr ret) (plist-get tr :prefix)))
              (result (string-join (gt-ensure-list (plist-get tr :result)) "\n")))
          (push (concat prefix result) lst)))
      ;; output
      (message "")
      (apply #'alert (string-join (nreverse lst) "\n") :title "*Go-Translate*" gt-alert-render-args))))


;;; [Taker] Prompt with new buffer

(defcustom gt-buffer-prompt-window-config
  '((display-buffer-reuse-window display-buffer-below-selected))
  "Window configuration of taker's buffer prompt window."
  :type 'sexp
  :group 'go-translate)

(defvar gt-buffer-prompt-name "*gt-taker*")

(defvar gt-buffer-prompt-map (make-sparse-keymap))

(declare-function gt-set-render "ext:go-translate")
(declare-function gt-set-engines "ext:go-translate")
(declare-function gt-translator-info "ext:go-translate")

(cl-defmethod gt-prompt ((taker gt-taker) translator (_ (eql 'buffer)))
  "Prompt the TAKER's result using a new buffer for TRANSLATOR.

Only works when taker's prompt slot is config as `buffer:

  :taker (gt-picker :prompt `buffer)

Edit the text in buffer and confirm with `C-c C-c', you can also change
target, engines and render in the buffer for the following translation."
  (with-slots (text target render engines _render _engines) translator
    (when (cdr text)
      (user-error "Multiple text cannot be prompted"))
    (cl-labels ((prop (s &optional fn not-key)
                  (let (args)
                    (unless not-key (setq args `(,@args face font-lock-keyword-face)))
                    (if fn (setq args `(,@args local-map (keymap (mode-line keymap (mouse-1 . ,fn)))
                                               mouse-face font-lock-warning-face)))
                    (apply #'propertize (format "%s" s) args)))
                (set-head-line ()
                  (setq header-line-format
                        (concat " " (cl-loop for (key . value) in `(("C-c C-c" . "to apply")
                                                                    ("C-c C-k" . "to cancel"))
                                             concat (format "%s %s " (prop key) value))
                                " " (propertize "Translate taking..." 'face 'font-lock-warning-face))))
                (set-mode-line ()
                  (setq mode-line-format
                        (let ((ms (concat "C-c C-n: Next Target\nC-c C-p: Prev Target\n\n"
                                          "C-c C-e: Set Engines\nC-c C-r: Set Render")))
                          (mapcar (lambda (item) (when item (propertize item 'help-echo ms)))
                                  (cl-destructuring-bind (_ eg rd)
                                      (ignore-errors (gt-translator-info translator))
                                    (list (prop (concat
                                                 (if-let (src (car target)) (concat "[" (prop src) "] → "))
                                                 "[" (mapconcat (lambda (s) (prop s)) (cdr target) ", ") "]")
                                                #'cycle-next-target t)
                                          (if eg (concat "  Engines: " (prop eg #'set-engines)))
                                          (if rd (concat "  Render: " (prop rd #'set-render)))))))))
                (cycle-next-target (&optional backwardp)
                  (interactive)
                  (setf target
                        (gt-target taker (make-instance
                                          (eieio-object-class translator)
                                          :text (list (buffer-string)))
                                   (if backwardp 'prev 'next)))
                  (set-mode-line))
                (cycle-prev-target ()
                  (interactive)
                  (cycle-next-target t))
                (set-engines ()
                  (interactive)
                  (gt-set-engines translator)
                  (set-mode-line))
                (set-render ()
                  (interactive)
                  (gt-set-render translator)
                  (set-mode-line))
                (set-local-keys ()
                  (local-set-key (kbd "C-c C-n") #'cycle-next-target)
                  (local-set-key (kbd "C-c C-p") #'cycle-prev-target)
                  (local-set-key (kbd "C-c C-e") #'set-engines)
                  (local-set-key (kbd "C-c C-r") #'set-render)))
      (let* ((ori (gt-collect-bounds-to-text (gt-ensure-list text)))
             (newtext (gt-read-from-buffer
                       :buffer gt-buffer-prompt-name
                       :initial-contents (or (car ori) "")
                       :catch 'gt-buffer-prompt
                       :window-config gt-buffer-prompt-window-config
                       :keymap gt-buffer-prompt-map
                       (set-head-line)
                       (set-mode-line)
                       (set-local-keys))))
        (when (null newtext)
          (user-error ""))
        (when (zerop (length (string-trim newtext)))
          (user-error "Text should not be null, abort"))
        (unless (equal ori (list newtext))
          (setf text (gt-ensure-list newtext)))))))


;;; [Taker] pdf-view-mode

(declare-function pdf-view-active-region-p "ext:pdf-view.el" t t)
(declare-function pdf-view-active-region-text "ext:pdf-view.el" t t)

(cl-defmethod gt-text-at-point (_thing (_ (eql 'pdf-view-mode)))
  (if (pdf-view-active-region-p)
      (pdf-view-active-region-text)
    (user-error "You should make a selection before translate")))

(provide 'gt-extension)

;;; gt-extension.el ends here
