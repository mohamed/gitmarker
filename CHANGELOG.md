# Changelog

## 1.0.0

First release.

- Google Keep-style notes in a masonry grid: create, edit, pin, colour,
  label, move to folders and delete (with Undo); search, label, folder and
  colour filters.
- Notes are Markdown files in a Git repository: plain Markdown, or managed
  notes with YAML front matter for pin, colour and labels. Existing
  repositories are scanned recursively.
- Every change is a commit. Sync over a local path, HTTPS (personal access
  token) or SSH (key file or agent): fast-forward, push, or rebase onto the
  remote; on a conflict, keep the remote version, force push, or leave both.
- History of each note, following renames, read-only with copy, and back to
  the latest version.
- Markdown preview with checklists you can tick, code blocks, bold, italic,
  links and TeX math.
- Arabic, Chinese and mixed scripts: every line takes its own direction.
- Git through dargit, a pure-Dart Git: no native libraries.
- Android, iOS, Linux, macOS and Windows.
