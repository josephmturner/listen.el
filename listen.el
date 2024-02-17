;;; listen.el --- Music player                    -*- lexical-binding: t; -*-

;; Copyright (C) 2024  Adam Porter

;; Author: Adam Porter <adam@alphapapa.net>
;; Keywords:
;; Package-Requires: ((emacs "29.1") (emms "11") (persist "0.6"))

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

;;; Commentary:

;; 

;;; Code:

;;;; Requirements

(require 'cl-lib)

(require 'listen-lib)
(require 'listen-vlc)

;;;; Variables

(defvar listen-mode-update-mode-line-timer nil)

;;;; Customization

(defgroup listen nil
  "Music player."
  :group 'applications)

(defcustom listen-directory "~/Music"
  "Default music directory."
  :type 'directory)

;;;; Functions

(cl-defmethod listen--running-p ((player listen-player))
  "Return non-nil if PLAYER is running."
  (process-live-p (listen-player-process player)))

;;;; Mode

(defvar listen-mode-lighter nil)

;;;###autoload
(define-minor-mode listen-mode
  "Listen to queues of tracks and show status in mode line."
  :global t
  (let ((lighter '(listen-mode listen-mode-lighter)))
    (if listen-mode
        (progn
          (when (timerp listen-mode-update-mode-line-timer)
            ;; Cancel any existing timer.  Generally shouldn't happen, but not impossible.
            (cancel-timer listen-mode-update-mode-line-timer))
          (setf listen-mode-update-mode-line-timer (run-with-timer nil 1 #'listen--update-lighter))
          ;; Avoid adding the lighter multiple times if the mode is activated again.
          (cl-pushnew lighter global-mode-string :test #'equal))
      (when listen-mode-update-mode-line-timer
        (cancel-timer listen-mode-update-mode-line-timer)
        (setf listen-mode-update-mode-line-timer nil))
      (setf global-mode-string
            (remove lighter global-mode-string)))))

(defcustom listen-lighter-format 'remaining
  "Time elapsed/remaining format."
  :type '(choice (const remaining)
                 (const elapsed)))

(defun listen-mode-lighter ()
  "Return lighter for `listen-mode'."
  (cl-labels ((format-time (seconds)
                (format-seconds "%h:%z%.2m:%.2s" seconds))
              (format-track ()
                (let ((info (listen--info listen-player)))
                  (format "%s: %s" (alist-get "artist" info nil nil #'equal)
                          (alist-get "title" info nil nil #'equal))))
              (format-status ()
                (pcase (listen--status listen-player)
                  ("playing" "▶")
                  ("paused" "⏸")
                  ("stopped" "■"))))
    (apply #'concat "🎵:"
           (if (and (listen--running-p listen-player)
                    (listen--playing-p listen-player))
               (list (format-status) " " (format-track)
                     " ("
                     (pcase listen-lighter-format
                       ('remaining (concat "-" (format-time (- (listen--length listen-player)
                                                               (listen--elapsed listen-player)))))
                       (_ (concat (format-time (listen--elapsed listen-player))
                                  "/"
                                  (format-time (listen--length listen-player)))))
                     ") ")
             (list "■ ")))))

(declare-function listen-queue-play "listen-queue")
(declare-function listen-queue-next-track "listen-queue")
(defun listen--update-lighter (&rest _ignore)
  "Update `listen-mode-lighter'."
  (unless (listen--playing-p listen-player)
    (when-let ((queue (map-elt (listen-player-etc listen-player) :queue))
               (next-track (listen-queue-next-track queue))) 
      (listen-queue-play queue next-track)))
  (setf listen-mode-lighter
        (when (and listen-player (listen--running-p listen-player))
          (listen-mode-lighter))))

;;;; Commands

(defun listen-next (player)
  "Play next track in PLAYER's queue."
  (interactive (list listen-player))
  (listen-queue-next (map-elt (listen-player-etc listen-player) :queue)))

(defun listen-pause (player)
  (interactive (list listen-player))
  (listen--pause player))

;; (defun listen-stop (player)
;;   (interactive (list listen-player))
;;   (listen--stop player))

;;;###autoload
(defun listen-play (player file)
  (interactive
   (list (listen--player)
         (read-file-name "Play file: " listen-directory nil t)))
  (listen--play player file))

(defun listen-volume (volume)
  "Set volume to VOLUME %."
  (interactive
   (let ((volume (floor (listen--volume (listen--player)))))
     (list (read-number "Volume %: " volume))))
  (listen--volume (listen--player) volume))

(defun listen-seek (seconds)
  "Seek to SECONDS.
Interactively, read a position timestamp, like \"23\" or
\"1:23\", with optional -/+ prefix for relative seek."
  (interactive
   (let* ((position (read-string "Seek to position: "))
          (prefix (when (string-match (rx bos (group (any "-+")) (group (1+ anything))) position)
                    (prog1 (match-string 1 position)
                      (setf position (match-string 2 position)))))
          (seconds (listen-read-time position)))
     (list (concat prefix (number-to-string seconds)))))
  (listen--seek (listen--player) seconds))

(defun listen-read-time (time)
  "Return TIME in seconds.
TIME is an HH:MM:SS string."
  (string-match (rx (group (1+ num)) (optional ":" (group (1+ num)) (optional ":" (group (1+ num))))) time)
  (let ((fields (nreverse
                 (remq nil
                       (list (match-string 1 time)
                             (match-string 2 time)
                             (match-string 3 time)))))
        (factors '(1 60 3600)))
    (cl-loop for field in fields
             for factor in factors
             sum (* (string-to-number field) factor))))

(defun listen-quit (player)
  "Quit PLAYER."
  (interactive
   (list (listen--player)))
  (delete-process (listen-player-process player))
  (setf listen-player nil))

;;;; Transient

(require 'transient)

;;;###autoload
(transient-define-prefix listen ()
  "Show Listen menu."
  :refresh-suffixes t
  [["Listen"
    :description
    (lambda ()
      (if listen-player
          (concat "Listening: " (listen-mode-lighter))
        "Not listening"))
    ("SPC" "Pause" listen-pause)
    ("p" "Play" listen-play)
    ;; ("ESC" "Stop" listen-stop)
    ("n" "Next" listen-next)]]
  [[]]
  ["Queue mode"
   :description
   (lambda ()
     (if-let ((queue (map-elt (listen-player-etc listen-player) :queue)))
         (format "Queue: %s (track %s/%s)" (listen-queue-name queue)
                 (cl-position (listen-queue-current queue) (listen-queue-tracks queue))
                 (length (listen-queue-tracks queue)))
       "No queue"))
   ("Q" "Show" listen-queue)
   ("P" "Play another queue" listen-queue-play)
   ("N" "New" listen-queue-new)
   ("A" "Add files" listen-queue-add-files)
   ("T" "Select track" (lambda ()
                         "Call `listen-queue-play' with prefix."
                         (interactive)
                         (let ((current-prefix-arg '(4)))
                           (call-interactively #'listen-queue-play))))
   ("D" "Discard" listen-queue-discard)
   ])

(provide 'listen)

;;; listen.el ends here
