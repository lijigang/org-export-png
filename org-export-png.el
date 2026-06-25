;;; org-export-png.el --- Export an Org region to a beautifully typeset PNG -*- lexical-binding: t; -*-

;; Copyright (C) 2026 lijigang

;; Author: lijigang <i@lijigang.com>
;; URL: https://github.com/lijigang/org-export-png
;; Version: 0.1.0
;; Keywords: org, export, image, convenience, i18n
;; Package-Requires: ((emacs "27.1"))

;; This file is not part of GNU Emacs.

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or (at
;; your option) any later version.
;;
;; This program is distributed in the hope that it will be useful, but
;; WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
;; General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:
;;
;; Select a region (or a subtree, or the whole buffer) and export it to a PNG
;; image with high-quality typography — handy for sharing a snippet as a card
;; on chat / 微信 / 小红书.  Pipeline:
;;
;;   Org region --(ox-html)--> HTML body --(template + CSS)--> headless Chrome
;;   --(--screenshot)--> PNG  --(ImageMagick -trim, optional)--> tight card.
;;
;; Typography follows the Chinese Copywriting Guidelines
;; (https://github.com/sparanoid/chinese-copywriting-guidelines): the spacing
;; between CJK and Latin/digits is produced by the CSS `text-autospace'
;; property (Chrome 131+), so the source text is never mutated.  The default
;; font is `KingHwa_OldSong' (京華老宋体); set `org-export-png-font' /
;; `org-export-png-font-file' to use your own.
;;
;; Usage:
;;   - Add to `load-path' and (require 'org-export-png).
;;   - Select a region, then either:
;;       M-x org-export-png-region            ; direct command
;;       C-c C-e g g                          ; via org-export-dispatch
;;   - Without a region it exports the current subtree / buffer.
;;
;; Requirements: a Chromium-based browser (Chrome/Brave/Chromium); ImageMagick
;; is optional (used to trim surplus whitespace).  See the README for details.

;;; Code:

(require 'org)
(require 'ox-html)
(require 'subr-x)
(require 'url-util)
(require 'cl-lib)

(defgroup org-export-png nil
  "Export an Org region to a typeset PNG."
  :group 'org-export)

(defcustom org-export-png-font "KingHwa_OldSong"
  "CSS font-family used for body text."
  :type 'string)

(defcustom org-export-png-font-file
  (car (cl-loop for dir in '("~/Library/Fonts" "/Library/Fonts"
                             "~/.local/share/fonts" "~/.fonts"
                             "/usr/share/fonts" "/usr/local/share/fonts")
                nconc (append
                       (file-expand-wildcards (expand-file-name "京華老宋*.tt[fc]" dir))
                       (file-expand-wildcards (expand-file-name "*KingHwa*.tt[fc]" dir)))))
  "Absolute path to the body font file, embedded via @font-face so the font
loads deterministically (the system font-family lookup can be unreliable in
headless Chrome).  Auto-detects KingHwa_OldSong in the common macOS/Linux font
directories; nil falls back to the `org-export-png-font' family name only.
Set this to any .ttf/.ttc/.otf to embed a different font."
  :type '(choice (const nil) file))

(defcustom org-export-png-mono-font "KingHwa_OldSong"
  "CSS font-family for inline code and code blocks.
Set to e.g. \"Menlo\" or \"SF Mono\" for true monospaced code."
  :type 'string)

;; --- Layout: portrait card sized for comfortable reading on a phone ---

(defcustom org-export-png-width 460
  "Content width (the measure) in CSS px.  Narrow = portrait/tall card,
~18-20 CJK glyphs per line, comfortable on a phone screen."
  :type 'integer)

(defcustom org-export-png-padding 50
  "Padding around the content in CSS px (also the image margin)."
  :type 'integer)

(defcustom org-export-png-font-size 24
  "Base font size in CSS px.  At scale 2 this is 48px in the image — about
17pt when the card is viewed full-width on a phone."
  :type 'integer)

(defcustom org-export-png-line-height 1.9
  "Line height (unitless).  Slightly airy for comfortable phone reading."
  :type 'number)

(defcustom org-export-png-scale 2
  "Device scale factor.  2 yields crisp output on HiDPI screens."
  :type 'integer)

(defcustom org-export-png-max-height 6000
  "Render viewport height in CSS px.  Headless Chrome only paints content
within the viewport, so this must exceed the rendered content height; the
surplus is cropped away by the trim step.  Raise it for very long regions."
  :type 'integer)

(defcustom org-export-png-bg "#f7f3ea"
  "Background color (warm paper)."
  :type 'string)

(defcustom org-export-png-fg "#23201b"
  "Foreground (text) color."
  :type 'string)

(defcustom org-export-png-output-dir "~/Downloads"
  "Directory where PNG files are written."
  :type 'directory)

(defcustom org-export-png-open-after t
  "When non-nil, open the PNG after export."
  :type 'boolean)

(defcustom org-export-png-trim t
  "When non-nil and ImageMagick is available, trim surplus whitespace
and add a uniform border equal to `org-export-png-padding'."
  :type 'boolean)

(defcustom org-export-png-browser
  (seq-find #'file-executable-p
            '("/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
              "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser"
              "/Applications/Chromium.app/Contents/MacOS/Chromium"
              "/usr/bin/google-chrome"
              "/usr/bin/chromium"))
  "Path to a Chromium-based browser binary used for rendering."
  :type '(choice (const :tag "Auto / none" nil) file))

(defcustom org-export-png-magick
  (or (executable-find "magick") (executable-find "convert"))
  "Path to ImageMagick (magick/convert) for optional trimming."
  :type '(choice (const nil) file))

;;;; HTML template ------------------------------------------------------------

(defun org-export-png--file-url (path)
  "Return a percent-encoded file:// URL for PATH (keeps the path structure,
encodes CJK/space/special bytes so headless Chrome accepts it)."
  (concat "file://"
          (replace-regexp-in-string
           "[^A-Za-z0-9/._~-]"
           (lambda (s) (url-hexify-string s))
           (expand-file-name path))))

(defun org-export-png--font-face ()
  "Return an @font-face rule embedding the body font file, or \"\"."
  (if (and org-export-png-font-file (file-exists-p org-export-png-font-file))
      ;; url() first so the actual file is used deterministically (loading it
      ;; needs the --allow-file-access-from-files flag, set in the render call).
      ;; local() inside @font-face proved unreliable on its own.
      (format "@font-face{font-family:'%s';src:url('%s') format('truetype'),local('%s'),local('京華老宋体');font-display:block;}\n"
              org-export-png-font
              (org-export-png--file-url org-export-png-font-file)
              org-export-png-font)
    ""))

(defun org-export-png--css ()
  "Return the CSS for the card, parameterised by the customisation vars."
  (let ((f  org-export-png-font)
        (mf org-export-png-mono-font)
        (w  (number-to-string org-export-png-width))
        (p  (number-to-string org-export-png-padding))
        (fs (number-to-string org-export-png-font-size))
        (lh (number-to-string org-export-png-line-height))
        (bg org-export-png-bg)
        (fg org-export-png-fg))
    (string-join
     (list
      (org-export-png--font-face)
      "*{box-sizing:border-box;}"
      "html,body{margin:0;padding:0;background:" bg ";}"
      ".card{width:" w "px;margin:0 auto;padding:" p "px;background:" bg ";"
      "  font-family:'" f "',serif;font-size:" fs "px;line-height:" lh ";color:" fg ";"
      "  text-autospace:normal;text-spacing-trim:space-first;"
      "  overflow-wrap:break-word;word-break:break-word;"
      "  text-rendering:optimizeLegibility;-webkit-font-smoothing:antialiased;"
      "  font-feature-settings:'liga' 1,'kern' 1,'palt' 1;}"
      ".card>:first-child{margin-top:0;} .card>:last-child{margin-bottom:0;}"
      ".card p{margin:0 0 1.05em;text-align:justify;}"
      ".card h1,.card h2,.card h3,.card h4{line-height:1.45;margin:1.5em 0 .7em;font-weight:700;}"
      ".card h1{font-size:1.6em;} .card h2{font-size:1.34em;} .card h3{font-size:1.14em;}"
      ".card h4{font-size:1em;}"
      ".card ul,.card ol{margin:0 0 1.05em;padding-left:1.5em;}"
      ".card li{margin:.3em 0;}"
      ".card code{font-family:'" mf "',ui-monospace,SFMono-Regular,monospace;"
      "  background:#ece6da;padding:.05em .36em;border-radius:4px;font-size:.92em;"
      "  overflow-wrap:anywhere;}"
      ".card pre{background:#2b2824;color:#ece6da;padding:.9em 1.05em;border-radius:8px;"
      "  white-space:pre-wrap;overflow-wrap:anywhere;font-size:.78em;line-height:1.55;"
      "  font-family:'" mf "',ui-monospace,SFMono-Regular,monospace;}"
      ".card pre code{background:none;padding:0;color:inherit;font-size:1em;}"
      ".card a{color:#9c5a2f;text-decoration:none;border-bottom:1px solid #d8c4ad;}"
      ".card blockquote{margin:0 0 1.05em;padding:.1em 0 .1em 1em;"
      "  border-left:3px solid #cdb699;color:#5b554c;}"
      ".card table{border-collapse:collapse;margin:0 0 1.1em;font-size:.95em;}"
      ".card th,.card td{border:1px solid #cdbfa8;padding:.4em .7em;}"
      ".card th{background:#ece6da;font-weight:700;}"
      ".card hr{border:none;border-top:1px solid #d8c4ad;margin:1.5em 0;}"
      ".card img{max-width:100%;}")
     "")))   ; join with "" — a newline here would land *inside* split values (e.g. width:\n460\npx) and void them

(defun org-export-png--wrap (body)
  "Wrap HTML BODY in a full document with the card CSS."
  (concat "<!DOCTYPE html>\n<html lang=\"zh-Hans\"><head><meta charset=\"utf-8\">\n"
          "<style>\n" (org-export-png--css) "\n</style></head>\n"
          "<body><div class=\"card\">\n" body "\n</div></body></html>\n"))

;;;; Rendering ----------------------------------------------------------------

(defun org-export-png--render (html png)
  "Render HTML string to PNG file via headless Chrome.  Return PNG."
  (unless org-export-png-browser
    (user-error "org-export-png: no Chromium-based browser found; set `org-export-png-browser'"))
  (let* ((html-file (make-temp-file "org-export-png-" nil ".html" html))
         (total (+ org-export-png-width (* 2 org-export-png-padding)))
         (status
          (apply #'call-process org-export-png-browser nil nil nil
                 (list "--headless=new" "--no-sandbox" "--hide-scrollbars"
                       "--disable-gpu" "--allow-file-access-from-files"
                       (format "--force-device-scale-factor=%d" org-export-png-scale)
                       (format "--window-size=%d,%d" total org-export-png-max-height)
                       ;; Opaque bg matching the card, so -trim sees a uniform
                       ;; backdrop and crops cleanly (transparent bg breaks trim).
                       (format "--default-background-color=%sff"
                               (string-remove-prefix "#" org-export-png-bg))
                       "--virtual-time-budget=3000"
                       (format "--screenshot=%s" (expand-file-name png))
                       (concat "file://" html-file)))))
    (ignore-errors (delete-file html-file))
    (unless (and (eq status 0) (file-exists-p png))
      (user-error "org-export-png: Chrome render failed (status %s)" status))
    ;; Optional: trim whitespace + uniform border.
    (when (and org-export-png-trim org-export-png-magick)
      (let ((b (number-to-string (* org-export-png-scale org-export-png-padding))))
        (call-process org-export-png-magick nil nil nil
                      (expand-file-name png) "-trim" "+repage"
                      "-bordercolor" org-export-png-bg "-border" b
                      (expand-file-name png))))
    (expand-file-name png)))

(defun org-export-png--from-html-body (body &optional png)
  "Build the card from HTML BODY and render to PNG (default: timestamped)."
  (let ((png (expand-file-name
              (or png (format-time-string "org-export-%Y%m%dT%H%M%S.png")
                  )
              (and (not png) (expand-file-name org-export-png-output-dir)))))
    (org-export-png--render (org-export-png--wrap body) png)))

;;;; Pangu: pad emphasis markers sitting against CJK --------------------------

(defcustom org-export-png-pangu t
  "When non-nil, insert a space where an Org emphasis marker (=code=, ~verb~,
*bold*, /italic/) sits directly against a CJK character.  Org does not parse a
marker that touches full-width punctuation, so without this the literal marker
leaks into the image.  Your buffer is never modified — only the rendered copy.
Src/example blocks are left untouched."
  :type 'boolean)

(defconst org-export-png--cjk
  "[　-〿㐀-䶿一-鿿豈-﫿＀-￯]"
  "Regexp class: CJK ideographs and CJK / full-width punctuation.")

(defun org-export-png--pad-emphasis (text)
  "Return TEXT with Org emphasis markers padded at CJK boundaries.
Lines inside src/example/export blocks pass through unchanged."
  (let ((cjk org-export-png--cjk) (in-block nil) (out '()))
    (dolist (line (split-string text "\n"))
      (cond
       ((string-match-p "^[ \t]*#\\+begin_\\(src\\|example\\|export\\)" line)
        (setq in-block t) (push line out))
       ((string-match-p "^[ \t]*#\\+end_\\(src\\|example\\|export\\)" line)
        (setq in-block nil) (push line out))
       (in-block (push line out))
       (t
        (dolist (m '("=" "~" "*" "/"))
          (let ((mc (regexp-quote m)))
            ;; CJK + emphasis-span -> CJK + space + emphasis-span
            (setq line (replace-regexp-in-string
                        (concat "\\(" cjk "\\)\\(" mc "[^" m " \t\n][^" m "\n]*" mc "\\)")
                        "\\1 \\2" line))
            ;; emphasis-span + CJK -> emphasis-span + space + CJK
            (setq line (replace-regexp-in-string
                        (concat "\\(" mc "[^" m "\n]*[^" m " \t\n]" mc "\\)\\(" cjk "\\)")
                        "\\1 \\2" line))))
        (push line out))))
    (mapconcat #'identity (nreverse out) "\n")))

;;;; Public API ---------------------------------------------------------------

(defun org-export-png--finish (png)
  "Report PNG and optionally open it.  Return PNG."
  (message "org-export-png: wrote %s" png)
  (when org-export-png-open-after
    (if (fboundp 'browse-url-of-file) (browse-url-of-file png)
      (call-process "open" nil nil nil png)))
  png)

;;;###autoload
(defun org-export-png-string (org-text &optional png)
  "Export ORG-TEXT (Org markup) to a PNG file; return its path.
Applies CJK emphasis padding when `org-export-png-pangu' is non-nil.
Batch-testable."
  (let* ((txt (if org-export-png-pangu
                  (org-export-png--pad-emphasis org-text) org-text))
         (body (org-export-string-as
                txt 'html t
                '(:with-toc nil :with-sub-superscript nil :with-smart-quotes t))))
    (org-export-png--from-html-body body png)))

(defun org-export-png--scope-text (&optional subtreep)
  "Return Org text for the active region, the subtree (if SUBTREEP), or buffer."
  (cond
   ((org-region-active-p)
    (buffer-substring-no-properties (region-beginning) (region-end)))
   (subtreep
    (save-restriction (org-narrow-to-subtree)
                      (buffer-substring-no-properties (point-min) (point-max))))
   (t (buffer-substring-no-properties (point-min) (point-max)))))

;;;###autoload
(defun org-export-png-region ()
  "Export the active region (or whole buffer) to a typeset PNG.
With an active region, only that region is rendered."
  (interactive)
  (org-export-png--finish (org-export-png-string (org-export-png--scope-text))))

;;;; org-export-dispatch backend ----------------------------------------------

(defun org-export-png--dispatch (&optional _async subtreep _visiblep _body-only _ext-plist)
  "Entry point used from `org-export-dispatch' (key P).
Honours an active region and subtree scope; runs the same pipeline."
  (org-export-png--finish (org-export-png-string (org-export-png--scope-text subtreep))))

;; NOTE: key must NOT be ?P — org-export-dispatch hard-codes ?P for Publish
;; (ox.el: first-key ?P only maps f/p/x/a; anything else dispatches to nil).
(org-export-define-derived-backend 'png 'html
  :menu-entry
  '(?g "Export to PNG image"
       ((?g "As PNG (region/subtree/buffer)" org-export-png--dispatch))))

(provide 'org-export-png)
;;; org-export-png.el ends here
