;;; org-export-png-test.el --- Tests for org-export-png -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'org-export-png)

(defun org-export-png-test--html (org-text)
  "Return the HTML that `org-export-png-string' builds for ORG-TEXT."
  (let (captured)
    (cl-letf (((symbol-function 'org-export-png--render)
               (lambda (html _png)
                 (setq captured html)
                 "/tmp/org-export-png-test.png")))
      (org-export-png-string org-text "/tmp/org-export-png-test.png"))
    captured))

(defun org-export-png-test--count (regexp string)
  "Count non-overlapping REGEXP matches in STRING."
  (let ((start 0) (count 0))
    (while (string-match regexp string start)
      (setq count (1+ count)
            start (match-end 0)))
    count))

(ert-deftest org-export-png-includes-mathjax-for-inline-formula ()
  (let ((html (org-export-png-test--html "行内：\\(e^{i\\pi}+1=0\\)。")))
    (should (string-match-p "id=\"MathJax-script\"" html))))

(ert-deftest org-export-png-includes-mathjax-for-display-formula ()
  (let ((html (org-export-png-test--html "\\[x=\\frac{1}{2}\\]")))
    (should (string-match-p "id=\"MathJax-script\"" html))))

(ert-deftest org-export-png-omits-mathjax-without-formula ()
  (let ((html (org-export-png-test--html "只有普通文字。")))
    (should-not (string-match-p "id=\"MathJax-script\"" html))))

(ert-deftest org-export-png-respects-org-mathjax-path ()
  (let ((html (org-export-png-test--html
               "#+HTML_MATHJAX: path:https://example.invalid/custom-mathjax.js\n\n\\(x\\)")))
    (should (string-match-p
             "src=\"https://example.invalid/custom-mathjax.js\"" html))))

(ert-deftest org-export-png-keeps-single-designed-title ()
  (let ((html (org-export-png-test--html
               "#+title: Formula Card\n#+subtitle: One subtitle\n\n正文。")))
    (should (= 1 (org-export-png-test--count "class=\"card-title\"" html)))
    ;; The document <head> legitimately repeats the title in <title>; the
    ;; visible card itself must contain exactly one title and one subtitle.
    (should (= 1 (org-export-png-test--count
                  "<h1>Formula Card</h1>" html)))
    (should (= 1 (org-export-png-test--count
                  "<p class=\"card-subtitle\">One subtitle</p>" html)))
    (should-not (string-match-p "class=\"title\"" html))))

(ert-deftest org-export-png-keeps-card-surface ()
  (let ((html (org-export-png-test--html "正文。")))
    (should (string-match-p "class=\"card\"" html))
    (should (string-match-p "lang=\"zh-Hans\"" html))
    (should (string-match-p "text-autospace:normal" html))))

(provide 'org-export-png-test)
;;; org-export-png-test.el ends here
