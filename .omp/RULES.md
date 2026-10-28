# Project rules

- NEVER commit source, comments, tests, fixtures, documentation or commit
  messages that reference a manga site: no site names, domains, URLs, mirrors,
  endpoints, scraped content or screenshots.
- Site-specific material goes only in the git-ignored `SiteTests/` directory
  (`site-notes.local.md` likewise); never stage it, never `git add -f` it, never
  copy it into a tracked file.
- Before committing, check the staged diff for site names, domains and URLs.
