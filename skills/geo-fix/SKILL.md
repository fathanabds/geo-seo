---
name: geo-fix
description: Closed-loop GEO remediation. Consumes a GEO-AUDIT-REPORT.md, triages findings into auto/review/skip buckets, applies framework-aware fixes to the target frontend repo, runs a build + Playwright smoke + render-verification QA gate, re-audits, and writes a score-delta diff. Loops until no auto fixes remain or scores plateau. Works on any project — Next.js, Vite/React, Astro, Nuxt, SvelteKit, plain HTML.
allowed-tools:
  - Read
  - Edit
  - Write
  - Grep
  - Glob
  - Bash
  - WebFetch
---

# GEO Fix Orchestration Skill

## Purpose

This skill closes the loop on the GEO audit. The `/geo-audit` skill produces a `GEO-AUDIT-REPORT.md` listing what's wrong. `/geo-fix` consumes that report, classifies findings by risk, applies the safe ones as concrete edits in the target frontend repo, validates the result with a QA gate, re-runs the audit, and diffs the score deltas — repeating until no more `auto` fixes remain or scores plateau.

## Recommended Workflow

Audit the **local production preview**, not the live URL, for the inner loop. What you fix is what you measure, no network round trips, the loop converges fast. Run a live audit once at the end to confirm production matches.

```bash
# 1. Baseline against the local production preview (auto-builds + serves)
/geo-audit

# 2. Fix loop — reuses the same URL from the report
/geo-fix

# 3. After merging + deploying, confirm production matches
/geo-audit https://your-live-site.com
```

You can also audit a live URL directly (`/geo-audit https://...`) if you don't have a local build environment. The loop still works — it just won't see fixes until you deploy.

## Invocation

```
/geo-fix                                    # uses ./GEO-AUDIT-REPORT.md and CWD
/geo-fix <project-path>                     # report at <project-path>/GEO-AUDIT-REPORT.md
/geo-fix --report <path> --project <path>   # explicit override
/geo-fix --dry-run                          # triage only — produces GEO-FIX-PLAN.md, no edits
/geo-fix --max-cycles <N>                   # default 3, hard cap 5
```

If the report doesn't exist at the resolved path, stop and tell the user to run `/geo-audit` first.

---

## The Loop

```
discover → triage → detect framework → apply (auto) → QA gate → re-audit → diff → terminate or loop
```

Each cycle writes artifacts to the project root:

| File | Written by | Purpose |
|---|---|---|
| `GEO-AUDIT-REPORT.md` | `/geo-audit` (Phase 0, input) | Findings to fix |
| `GEO-FIX-PLAN.md` | Phase 2 (triage) | Bucketed plan with file targets |
| `GEO-FIX-LOG.md` | Phase 4 (apply) | What was changed per category |
| `GEO-QA-REPORT.md` | Phase 5 (QA gate) | Build/smoke/render results |
| `GEO-AUDIT-DIFF.md` | Phase 7 (diff) | Score deltas, fixes landed, fixes deferred |

---

### Phase 0 — Discovery

1. Resolve `report_path` and `project_path` from args (defaults: `./GEO-AUDIT-REPORT.md`, CWD).
2. Verify the report exists. If not, exit with: "No report at <path>. Run `/geo-audit` first."
3. Extract `audited_url` from the report header (`**URL:** <url>` line). Classify it:
   - **Local** if the host is `localhost` or `127.0.0.1` — the inner loop will re-audit this URL via `/geo-audit`'s auto-preview mode, which rebuilds the project on each cycle.
   - **Remote** otherwise — the inner loop re-audits the live URL each cycle. Fixes won't register until the user deploys, so the loop will likely plateau after one cycle. Warn the user and offer to switch to the recommended local-preview flow.
4. Verify the project is a git repo (`git rev-parse --git-dir`). If not, warn the user; commits-per-category will be skipped and a single diff will be produced instead.
5. Capture baseline GEO Score from the report's Executive Summary table — store as `baseline_score`.

### Phase 1 — Framework Detection (run once, cached)

Read `<project_path>/package.json`. Classify the framework using these signals, in priority order:

| Framework | Detection signal | Schema injection location | Smoke route source |
|---|---|---|---|
| **Next.js (app router)** | `dependencies.next` AND `app/` directory exists | `app/layout.tsx` `metadata` export + JSON-LD via `<Script type="application/ld+json">` | `app/**/page.tsx` files |
| **Next.js (pages router)** | `dependencies.next` AND `pages/` exists, no `app/` | `pages/_document.tsx` + `next/head` `<Head>` | `pages/**/*.tsx` files |
| **Nuxt 3** | `dependencies.nuxt` | `nuxt.config.ts` `app.head` + `useHead()` composable | `pages/**/*.vue` |
| **Astro** | `dependencies.astro` | `src/layouts/*.astro` `<head>` block | `src/pages/**/*.astro` |
| **SvelteKit** | `dependencies.@sveltejs/kit` | `src/app.html` `%sveltekit.head%` + `<svelte:head>` | `src/routes/**/+page.svelte` |
| **Vite + React** | `dependencies.vite` AND `dependencies.react`, no SSR framework | `index.html` `<head>` directly | Inferred from `src/App.tsx` routes |
| **Plain HTML** | No `package.json` or no framework deps | Each `*.html` file `<head>` | All `*.html` files at root |
| **Generic** | Anything else | Best-effort: search for an HTML entry file | Fallback to `/` only |

Also detect available scripts in `package.json.scripts`:
- `build` — used for build gate
- `typecheck` / `type-check` / `tsc` — used for type gate (optional)
- `lint` — used for lint gate (optional)
- `test:e2e` / `playwright` — used as smoke test if present, else we run our own

Cache results to memory for the rest of the run.

### Phase 2 — Triage (delegate to `geo-fix-triage` agent)

Spawn the `geo-fix-triage` subagent with:
- The full `GEO-AUDIT-REPORT.md` contents
- The detected framework
- Read access to the project (so it can locate concrete file targets)

The agent returns a `GEO-FIX-PLAN.md` with each finding bucketed into `auto`, `review`, or `skip` and — for `auto` items — concrete file paths and the change to apply.

**Bucket rules** (the agent applies these; documented here so they're inspectable):

#### AUTO — safe to apply automatically
1. `llms.txt` creation/update (file-level addition, no app code touched)
2. `robots.txt` edits: AI crawler allows, `Sitemap:` reference, `Content-Signal:` directive
3. **Static** JSON-LD blocks: Organization, WebSite+SearchAction, BreadcrumbList — additive, no factual claims beyond what's already on the page
4. Missing meta tags: description (from existing H1/first paragraph), Open Graph, Twitter Card, canonical
5. Image alt text **only** when `<figcaption>`, surrounding heading, or filename gives unambiguous context
6. Removing deprecated schemas (HowTo, SpecialAnnouncement, CourseInfo) — pure deletion
7. Adding `dateModified` to existing Article schema (use file mtime or build timestamp)
8. Adding `speakable` cssSelector to existing Article schema
9. Heading hierarchy: missing H1 (insert from page title), multiple H1s (demote duplicates to H2)
10. Sitemap reference in robots.txt

#### REVIEW — produce proposal, do not auto-apply
1. Author bios / Person schema (factual claims about real people)
2. Article content rewrites for E-E-A-T
3. Citability passage rewrites
4. New page creation (About, FAQ, contact)
5. Product schema `offers` (prices, availability — must match reality)
6. LocalBusiness address, phone, hours (verification required)
7. Image alt text where context is ambiguous
8. Any JSON-LD asserting dates, prices, ratings, or other facts the agent can't verify

#### SKIP — off-site or not actionable in this repo
1. Wikipedia article creation
2. Reddit / YouTube / LinkedIn presence
3. Third-party industry citations
4. SSR migration / architectural changes (flag separately; not a fix)

The plan is the **only** output of this phase — no edits yet.

### Phase 3 — Dry-run gate

If `--dry-run` was passed, stop here. Print a summary of bucket counts and the path to `GEO-FIX-PLAN.md`. Exit.

Otherwise, show the user the bucket summary and continue.

### Phase 4 — Apply auto fixes (per category, with per-category commits)

Iterate the `auto` items grouped by **category** (llms.txt, robots.txt, schema, meta-tags, alt-text, headings, deprecated-schema-removal). For each category:

1. Apply all edits in that category using `Edit` / `Write`. Use the framework-specific injection location from Phase 1.
2. If git is available, commit only the changed files for that category:
   ```
   git add <changed files>
   git commit -m "geo-fix: <category> (cycle N)"
   ```
3. Append a `GEO-FIX-LOG.md` entry with the files changed and a one-line summary per fix.

If any single edit fails (e.g., file not found, ambiguous match), log it and continue with the rest. Failures move to the `review` bucket in the diff.

### Phase 5 — QA gate (delegate to `geo-fix-qa` agent)

Spawn the `geo-fix-qa` subagent with the project path, detected framework, sitemap URLs, and audited site URL. It runs:

1. **Build** — `npm run build` (or detected equivalent). Fail = halt the cycle.
2. **Typecheck** — if a typecheck script exists. Soft fail = continue but flag.
3. **Lint** — if a lint script exists. Soft fail = continue but flag.
4. **Smoke test** — Playwright on up to 5 routes (homepage + 4 from sitemap). Checks: 200 response, no console errors, page renders meaningful content.
5. **Render verification** — start the dev/preview server, hit each smoke route with `~/.claude/skills/geo/scripts/fetch_page.py <url> full`, and grep the rendered HTML for the JSON-LD blocks and meta tags we injected. If a fix was applied but doesn't appear in rendered HTML (classic CSR-not-SSR failure), the fix is logged as **landed-but-not-rendered** in the QA report.

The agent writes `GEO-QA-REPORT.md` and returns a status: `pass`, `soft-fail` (lint/type warnings but build + smoke OK), or `hard-fail` (build or smoke broken).

**On hard-fail:** revert the last category's commits (`git reset --hard HEAD~N`) if git is available, surface the QA report to the user, and stop the loop. Don't re-audit a broken site.

### Phase 6 — Re-audit

Copy the previous `GEO-AUDIT-REPORT.md` to `GEO-AUDIT-REPORT.cycle-<N>.md` for the diff, then invoke `/geo-audit`:

- If `audited_url` is **local**: invoke `/geo-audit` with **no URL** (from the project_path CWD). Its auto-preview mode rebuilds and serves the latest source, so this cycle's fixes are picked up.
- If `audited_url` is **remote**: invoke `/geo-audit <audited_url>`. Fixes won't show up until deploy — surface this in the cycle summary.

The audit writes a new `GEO-AUDIT-REPORT.md`, overwriting the previous one.

### Phase 7 — Diff and terminator check

Write `GEO-AUDIT-DIFF.md` comparing the previous and new reports:
- Overall GEO Score delta
- Per-category score deltas (six categories from the audit's weighting table)
- Findings resolved (present in old, absent in new)
- Findings landed-but-not-rendered (from the QA report)
- Findings deferred to `review` bucket (still pending human approval)
- New findings introduced (if any — usually means a fix had a side effect)

**Terminator rules** — stop the loop if **any** is true:
1. No `auto` fixes remained in the latest triage.
2. Cycle count reached `--max-cycles` (default 3).
3. Score delta < 2 points for **two consecutive** cycles (plateau).
4. QA gate hard-failed.
5. New findings were introduced this cycle (cycle did net harm — halt for review).

Otherwise, loop back to Phase 2.

### Phase 8 — Final summary

After the loop terminates, print:
- Cycles run
- Baseline → final GEO Score
- Per-category before/after table
- Count of fixes landed, deferred to review, blocked by QA
- Path to all artifacts (`GEO-FIX-PLAN.md`, `GEO-FIX-LOG.md`, `GEO-QA-REPORT.md`, `GEO-AUDIT-DIFF.md`)
- Next concrete actions:
  1. "Review `GEO-FIX-PLAN.md` review-bucket entries — N items need human approval."
  2. If `audited_url` was local: "After merging + deploying, run `/geo-audit <live-url>` to confirm production matches the local result. Differences usually mean CDN/edge config (Vercel, Cloudflare) is overriding a static file like `robots.txt`, or production env vars are changing SSR output."

---

## Cross-project portability

This skill must work on any frontend project, not just the one it's first built against. The portability contract:

- **No hardcoded paths.** Everything is derived from `project_path` (default CWD) and `report_path` (default `./GEO-AUDIT-REPORT.md`).
- **Framework detection runs first** and routes fixes through framework-specific injection locations. A schema fix in a Next.js app router project lands in `app/layout.tsx`; in a Vite project it lands in `index.html`. The triage agent is responsible for resolving this per fix.
- **Smoke routes are auto-discovered** from the sitemap the audit already crawled — never hardcoded.
- **The audited URL is read from the report**, never assumed.

When porting to a new framework, the only file that should need editing is the Phase 1 detection table above and the framework-specific templates inside the `geo-fix-triage` agent.

---

## Quality Gates and Safety

- **Always operate on a clean working tree.** If `git status` shows uncommitted changes at start, stop and ask the user to commit or stash. Mixing user work with auto-fixes makes reverts ambiguous.
- **One category per commit.** Never bundle schema + meta + robots into a single commit — it makes the QA report unreadable when something breaks.
- **Never delete files** in the auto bucket. Removing deprecated schemas means deleting `<script type="application/ld+json">` blocks, not files.
- **Never modify package.json or lockfiles** in the auto bucket. Dependency changes always go to review.
- **Render verification is mandatory** for schema fixes. A schema added to a client component that never reaches the rendered HTML is worse than no fix — it inflates the local diff without affecting the audit.
- **Max cycles is a hard cap.** Even with `--max-cycles 100`, the runtime stops at 5 to prevent runaway loops.

---

## Output: GEO-AUDIT-DIFF.md format

```markdown
# GEO Audit Diff: [Site Name]

**Cycles run:** [N]
**Baseline → Final GEO Score:** [X] → [Y] (Δ +[Z])

## Score Deltas

| Category | Baseline | Cycle 1 | Cycle 2 | Final | Δ |
|---|---|---|---|---|---|
| AI Citability | [X] | [X] | [X] | [X] | [Δ] |
| Brand Authority | [X] | [X] | [X] | [X] | [Δ] |
| Content E-E-A-T | [X] | [X] | [X] | [X] | [Δ] |
| Technical GEO | [X] | [X] | [X] | [X] | [Δ] |
| Schema & Structured Data | [X] | [X] | [X] | [X] | [Δ] |
| Platform Optimization | [X] | [X] | [X] | [X] | [Δ] |
| **Overall** | [X] | [X] | [X] | [X] | **[Δ]** |

## Fixes Landed

[Table: category, finding, file(s), cycle]

## Fixes Deferred to Review

[Table: category, finding, reason, proposed change location]

## Fixes Landed but Not Rendered

[Schema or meta fixes that appear in source but were not in rendered HTML — typically CSR-only injection. Action: move to SSR location.]

## New Findings Introduced

[Findings that appeared after fixes that weren't present in baseline. Investigate before continuing.]

## Termination Reason

[One of: no-auto-fixes-remaining | max-cycles-reached | score-plateau | qa-hard-fail | new-findings-introduced]
```
