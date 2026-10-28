# MoeReader — agent notes

## Site references are never committed

Nothing committed may name or link a manga site: not source code, comments,
tests, fixtures, documentation, commit messages, branch names, or PR text. That
covers site names, domains, URLs, mirrors, API endpoints, scraped HTML/JSON and
screenshots of one.

Write behaviour generically instead:

- Good: "some extensions reject a second concurrent `getMangaUpdate` for one
  manga with `IllegalStateException`".
- Bad: a named site (or its extension name) followed by the same explanation.

The extension API's own error text is fine: it describes the contract, not a
site.

Site-specific material — live-host notes, URLs, cookies, APKs, logs — belongs in
`SiteTests/`, which is git-ignored (see `SiteTests/README.md`). NEVER `git add`,
`git add -f`, or otherwise commit anything under `SiteTests/` or
`site-notes.local.md`, and never copy its content into a tracked file.

Check `git diff --cached` for site names, domains and URLs before every commit.

## Layout

`README.md` describes the app. Per-interpreter and per-runtime notes live in
`MoeReader/*/README.md`; the host and its VM are documented in
`SuwayomiHost/README.md`.
