# Repository Guidelines (Fork-Focused)

## Scope

- This repository is a personal fork of `openclaw/openclaw`.
- Work only on this fork's goals and local changes.
- Upstream syncing (`fetch upstream`, `merge/rebase upstream`) is handled by the owner. Do not run upstream sync commands unless explicitly requested.

## Project Type

- This is a Node.js/TypeScript project.
- Prioritize CLI/runtime/docs/plugin workflows in this repo.
- Ignore unrelated platform guidance unless a task explicitly requires it.

## Local Environment (Debian via OrbStack)

- macOS mount path: `/Users/ronnie/OrbStack/debian/`
- SSH: `ssh ronnie@debian.orb.local`
- Repo path mapping:
  - macOS: `/Users/ronnie/OrbStack/debian/home/ronnie/openclaw`
  - Debian: `/home/ronnie/openclaw`
- Current known baseline (2026-02-13):
  - Debian 13 (trixie)
  - Node `v22.22.0`
  - Git `2.47.3`
  - `pnpm` and `bun` may not be preinstalled on fresh VM shells
- Bootstrap on fresh VM shell:
  - `corepack enable && corepack prepare pnpm@latest --activate`
  - optional Bun: `curl -fsSL https://bun.sh/install | bash`

## Code Layout

- Source: `src/`
- Tests: colocated `*.test.ts`
- Extensions/plugins: `extensions/*`
- Docs: `docs/`
- Build output: `dist/`

## Build, Test, and Lint

- Runtime baseline: Node 22+
- Install deps: `pnpm install`
- Dev run: `pnpm dev` or `pnpm openclaw ...`
- Build: `pnpm build`
- Type checks: `pnpm tsgo`
- Lint/format checks: `pnpm check`, `pnpm format`
- Fix format: `pnpm format:fix`
- Tests: `pnpm test`

## Fork Workflow Rules

- Keep commits scoped to the task; do not bundle unrelated edits.
- Do not switch branches unless explicitly requested.
- Do not use `git stash` unless explicitly requested.
- Do not use destructive git commands (`reset --hard`, `checkout --`, force cleanups) unless explicitly requested.
- If unrelated files are already dirty, leave them untouched and commit only files changed for the current task.

## Dependency and Plugin Rules

- Do not edit `node_modules`.
- Do not update/patch dependencies unless explicitly requested.
- For `extensions/*`, keep runtime deps in the extension's `dependencies`; avoid `workspace:*` in runtime `dependencies`.

## Documentation Rules

- Keep docs concise and operational.
- Internal docs links under `docs/**/*.md`: root-relative and without `.md` suffix.
- Do not edit `docs/zh-CN/**` unless explicitly requested.

## Security

- Never commit real secrets, tokens, phone numbers, or private hostnames.
- Use placeholder values in examples and docs.

## GitHub Text Formatting

- For GitHub issue/PR comments, use real newlines (literal multiline or `-F - <<'EOF'`).
- Never embed escaped `\\n` as line breaks.
