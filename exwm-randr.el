;;; exwm-randr.el --- RandR Module for EXWM  -*- lexical-binding: t -*-

;; Copyright (C) 2015-2018 Free Software Foundation, Inc.

;; Author: Chris Feng <chris.w.feng@gmail.com>

;; This file is part of GNU Emacs.

;; GNU Emacs is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; GNU Emacs is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; This module adds RandR support for EXWM.  Currently it requires external
;; tools such as xrandr(1) to properly configure RandR first.  This
;; dependency may be removed in the future, but more work is needed before
;; that.

;; To use this module, load, enable it and configure
;; `exwm-randr-workspace-monitor-plist' and `exwm-randr-screen-change-hook'
;; as follows:
;;
;;   (require 'exwm-randr)
;;   (setq exwm-randr-workspace-monitor-plist '(0 "VGA1"))
;;   (add-hook 'exwm-randr-screen-change-hook
;;             (lambda ()
;;               (start-process-shell-command
;;                "xrandr" nil "xrandr --output VGA1 --left-of LVDS1 --auto")))
;;   (exwm-randr-enable)
;;
;; With above lines, workspace 0 should be assigned to the output named "VGA1",
;; staying at the left of other workspaces on the output "LVDS1".  Please refer
;; to xrandr(1) for the configuration of RandR.

;; References:
;; + RandR (http://www.x.org/archive/X11R7.7/doc/randrproto/randrproto.txt)

;;; Code:

(require 'xcb-randr)
(require 'exwm-core)

(defgroup exwm-randr nil
  "RandR."
  :version "25.3"
  :group 'exwm)

(defcustom exwm-randr-refresh-hook nil
  "Normal hook run when the RandR module just refreshed."
  :type 'hook)

(defcustom exwm-randr-screen-change-hook nil
  "Normal hook run when screen changes."
  :type 'hook)

(defcustom exwm-randr-workspace-monitor-plist nil
  "Plist mapping workspaces to monitors.

In RandR 1.5 a monitor is a rectangle region decoupled from the physical
size of screens, and can be identified with `xrandr --listmonitors' (name of
the primary monitor is prefixed with an `*').  When no monitor is created it
automatically fallback to RandR 1.2 output which represents the physical
screen size.  RandR 1.5 monitors can be created with `xrandr --setmonitor'.
For example, to split an output (`LVDS-1') of size 1280x800 into two
side-by-side monitors one could invoke (the digits after `/' are size in mm)

    xrandr --setmonitor *LVDS-1-L 640/135x800/163+0+0 LVDS-1
    xrandr --setmonitor LVDS-1-R 640/135x800/163+640+0 none

If a monitor is not active, the workspaces mapped to it are displayed on the
primary monitor until it becomes active (if ever).  Unspecified workspaces
are all mapped to the primary monitor.  For example, with the following
setting workspace other than 1 and 3 would always be displayed on the
primary monitor where workspace 1 and 3 would be displayed on their
corresponding monitors whenever the monitors are active.

  \\='(1 \"HDMI-1\" 3 \"DP-1\")"
  :type '(plist :key-type integer :value-type string))

(with-no-warnings
  (define-obsolete-variable-alias 'exwm-randr-workspace-output-plist
    'exwm-randr-workspace-monitor-plist "27.1"))

(defvar exwm-workspace--fullscreen-frame-count)
(defvar exwm-workspace--list)
(declare-function exwm-workspace--count "exwm-workspace.el")
(declare-function exwm-workspace--set-active "exwm-workspace.el"
                  (frame active))
(declare-function exwm-workspace--set-desktop-geometry "exwm-workspace.el" ())
(declare-function exwm-workspace--set-fullscreen "exwm-workspace.el" (frame))
(declare-function exwm-workspace--show-minibuffer "exwm-workspace.el" ())
(declare-function exwm-workspace--update-workareas "exwm-workspace.el" ())

(defun exwm-randr--get-monitors ()
  "Get RandR monitors."
  (let (monitor-name geometry monitor-plist primary-monitor)
    (with-slots (monitors)
        (xcb:+request-unchecked+reply exwm--connection
            (make-instance 'xcb:randr:GetMonitors
                           :window exwm--root
                           :get-active 1))
      (dolist (monitor monitors)
        (with-slots (name primary x y width height) monitor
          (setq monitor-name (x-get-atom-name name)
                geometry (make-instance 'xcb:RECTANGLE
                                        :x x
                                        :y y
                                        :width width
                                        :height height)
                monitor-plist (plist-put monitor-plist monitor-name geometry))
          ;; Save primary monitor when available.
          (when (/= 0 primary)
            (setq primary-monitor monitor-name)))))
    (exwm--log "Primary monitor: %s" primary-monitor)
    (exwm--log "Monitors: %s" monitor-plist)
    (list primary-monitor monitor-plist)))

(defun exwm-randr--refresh ()
  "Refresh workspaces according to the updated RandR info."
  (let* ((result (exwm-randr--get-monitors))
         (primary-monitor (elt result 0))
         (monitor-plist (elt result 1))
         container-monitor-alist container-frame-alist)
    (when (and primary-monitor monitor-plist)
      (when exwm-workspace--fullscreen-frame-count
        ;; Not all workspaces are fullscreen; reset this counter.
        (setq exwm-workspace--fullscreen-frame-count 0))
      (dotimes (i (exwm-workspace--count))
        (let* ((monitor (plist-get exwm-randr-workspace-monitor-plist i))
               (geometry (lax-plist-get monitor-plist monitor))
               (frame (elt exwm-workspace--list i))
               (container (frame-parameter frame 'exwm-container)))
          (unless geometry
            (setq monitor primary-monitor
                  geometry (lax-plist-get monitor-plist primary-monitor)))
          (setq container-monitor-alist (nconc
                                         `((,container . ,(intern monitor)))
                                         container-monitor-alist)
                container-frame-alist (nconc `((,container . ,frame))
                                             container-frame-alist))
          (set-frame-parameter frame 'exwm-randr-monitor monitor)
          (set-frame-parameter frame 'exwm-geometry geometry)))
      ;; Update workareas.
      (exwm-workspace--update-workareas)
      ;; Resize workspace.
      (dolist (f exwm-workspace--list)
        (exwm-workspace--set-fullscreen f))
      (xcb:flush exwm--connection)
      ;; Raise the minibuffer if it's active.
      (when (and (active-minibuffer-window)
                 (exwm-workspace--minibuffer-own-frame-p))
        (exwm-workspace--show-minibuffer))
      ;; Set _NET_DESKTOP_GEOMETRY.
      (exwm-workspace--set-desktop-geometry)
      ;; Update active/inactive workspaces.
      (dolist (w exwm-workspace--list)
        (exwm-workspace--set-active w nil))
      ;; Mark the workspace on the top of each monitor as active.
      (dolist (xwin
               (reverse
                (slot-value (xcb:+request-unchecked+reply exwm--connection
                                (make-instance 'xcb:QueryTree
                                               :window exwm--root))
                            'children)))
        (let ((monitor (cdr (assq xwin container-monitor-alist))))
          (when monitor
            (setq container-monitor-alist
                  (rassq-delete-all monitor container-monitor-alist))
            (exwm-workspace--set-active (cdr (assq xwin container-frame-alist))
                                        t))))
      (xcb:flush exwm--connection)
      (run-hooks 'exwm-randr-refresh-hook))))

(defun exwm-randr--on-ScreenChangeNotify (_data _synthetic)
  (exwm--log)
  (run-hooks 'exwm-randr-screen-change-hook)
  (exwm-randr--refresh))

(defun exwm-randr--init ()
  "Initialize RandR extension and EXWM RandR module."
  (if (= 0 (slot-value (xcb:get-extension-data exwm--connection 'xcb:randr)
                       'present))
      (error "[EXWM] RandR extension is not supported by the server")
    (with-slots (major-version minor-version)
        (xcb:+request-unchecked+reply exwm--connection
            (make-instance 'xcb:randr:QueryVersion
                           :major-version 1 :minor-version 5))
      (if (or (/= major-version 1) (< minor-version 5))
          (error "[EXWM] The server only support RandR version up to %d.%d"
                 major-version minor-version)
        ;; External monitor(s) may already be connected.
        (run-hooks 'exwm-randr-screen-change-hook)
        (exwm-randr--refresh)
        (xcb:+event exwm--connection 'xcb:randr:ScreenChangeNotify
                    #'exwm-randr--on-ScreenChangeNotify)
        (xcb:+request exwm--connection
            (make-instance 'xcb:randr:SelectInput
                           :window exwm--root
                           :enable xcb:randr:NotifyMask:ScreenChange))
        (xcb:flush exwm--connection)
        (add-hook 'exwm-workspace-list-change-hook #'exwm-randr--refresh))))
  ;; Prevent frame parameters introduced by this module from being
  ;; saved/restored.
  (dolist (i '(exwm-randr-monitor))
    (unless (assq i frameset-filter-alist)
      (push (cons i :never) frameset-filter-alist))))

(defun exwm-randr--exit ()
  "Exit the RandR module."
  (remove-hook 'exwm-workspace-list-change-hook #'exwm-randr--refresh))

(defun exwm-randr-enable ()
  "Enable RandR support for EXWM."
  (add-hook 'exwm-init-hook #'exwm-randr--init)
  (add-hook 'exwm-exit-hook #'exwm-randr--exit))



(provide 'exwm-randr)

;;; exwm-randr.el ends here
