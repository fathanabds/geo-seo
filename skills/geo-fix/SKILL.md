---
name: geo-fix
description: Closed-loop GEO remediation. Consumes a GEO-AUDIT-REPORT.md, triages findings into auto/review/skip buckets (review further split into interactive vs offline), applies framework-aware auto-fixes, runs a build + Playwright smoke + render-verification QA gate, re-audits, writes a score-delta diff. Loops until no auto fixes remain or scores plateau, then walks the user through an opt-in Q&A for interactive-review items (missing schema fields, sameAs URLs, Offer prices, addresses). Works on any project — Next.js, Vite/React, Astro, Nuxt, SvelteKit, plain HTML.
allowed-tools:
  - Read
  - Edit
  - Write
  - Grep
  - Glob
  - Bash
  - WebFetch
  - AskUserQuestion
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
/geo-fix --no-interactive                   # skip Phase 8 Q&A entirely
```

If the report doesn't exist at the resolved path, stop and tell the user to run `/geo-audit` first.

---

## The Loop

```
discover → triage → detect framework → apply (auto) → QA gate → re-audit → diff → loop
                                                                              ↓
                                                          terminate → interactive review (Q&A) → final summary
```

Each cycle writes artifacts to the project root:

| File | Written by | Purpose |
|---|---|---|
| `GEO-AUDIT-REPORT.md` | `/geo-audit` (Phase 0, input) | Findings to fix |
| `GEO-FIX-PLAN.md` | Phase 2 (triage) | Bucketed plan with file targets and interactive question templates |
| `GEO-FIX-LOG.md` | Phase 4 (apply) | What was changed per category |
| `GEO-QA-REPORT.md` | Phase 5 (QA gate) | Build/smoke/render results |
| `GEO-AUDIT-DIFF.md` | Phase 7 (diff) | Score deltas, fixes landed, fixes deferred |
| `GEO-INTERACTIVE-LOG.md` | Phase 8 (Q&A) | Per-question answers, skips, applied changes, QA results |

---

### Phase 0 — Discovery

1. Resolve `report_path` and `project_path` from args (defaults: `./GEO-AUDIT-REPORT.md`, CWD).
2. Verify the report exists. If not, exit with: "No report at <path>. Run `/geo-audit` first."
3. Extract `audited_url` from the report header (`**URL:** <url>` line). Classify it:
   - **Local** if the host is `localhost` or `127.0.0.1` — the inner loop will re-audit this URL via `/geo-audit`'s auto-preview mode, which rebuilds the project on each cycle.
   - **Remote** otherwise — the inner loop re-audits the live URL each cycle. Fixes won't register until the user deploys, so the loop will likely plateau after one cycle. Warn the user and offer to switch to the recommended local-preview flow.
4. **Git readiness.** If `git rev-parse --git-dir` fails, warn the user; commits-per-category and the branch-switch step are skipped, and a single diff will be produced instead. Otherwise (git repo):

   **a. Detect base branch.** Run `git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null` and strip the `refs/remotes/origin/` prefix to get `base_branch` (typically `main` or `master`). If that fails, fall back in order: local `main`, then local `master`. If neither exists, exit with: `Cannot determine base branch. Set origin/HEAD or create a main/master branch.`

   **b. Fetch latest.** If a remote is configured (`git remote` returns non-empty), run `git fetch origin <base_branch>` with a 30-second timeout. On failure or no remote, warn `No remote configured — proceeding with local <base_branch>. Code may be stale.` and continue. Determine the base ref to use going forward: `origin/<base_branch>` if fetch succeeded, else local `<base_branch>`.

   **c. Dirty-tree check (excludes our own artifacts).** Run:
   ```bash
   git status --porcelain -- ':(exclude)GEO-*.md'
   ```
   If output is non-empty, **exit immediately with no further actions**. Print exactly this message and stop the skill:
   ```
   Working tree has uncommitted changes (excluding GEO-* artifacts):
   <list of files>

   Resolve these manually before re-running /geo-fix:
     - git stash push -m "pre-geo-fix" -- <files>   (to set aside)
     - git commit -m "..." <files>                  (to keep on current branch)
     - git checkout -- <files>                      (to discard)

   /geo-fix must not modify your working tree to satisfy this check.
   ```

   **HARD RULE — DO NOT BYPASS:** the skill MUST NOT auto-stash, auto-commit, auto-revert, or in any way modify the user's working tree to clear this state. Even if the change appears trivial (e.g., a one-line cosmetic tweak), even if it appears unrelated to GEO, even if the user previously ran with similar changes — the only acceptable response is to print the refusal message and stop. The user's working tree is theirs to manage. Auto-stashing silently relocates user work to a list (`git stash list`) where it can be forgotten, which is worse than refusing outright.

   This check excludes `GEO-AUDIT-REPORT.md`, `GEO-AUDIT-REPORT.cycle-*.md`, `GEO-FIX-PLAN.md`, `GEO-FIX-LOG.md`, `GEO-QA-REPORT.md`, and `GEO-AUDIT-DIFF.md` — they're skill outputs, not user changes.

   **d. Switch to `chore/geo-fix`.** Capture `previous_branch = $(git rev-parse --abbrev-ref HEAD)` first for the final summary. Then:
   - If branch does not exist (`git show-ref --verify --quiet refs/heads/chore/geo-fix` fails): create it from the base ref. `git checkout -b chore/geo-fix <base_ref>`.
   - If branch exists: `git checkout chore/geo-fix`, then `git rebase <base_ref>` to bring it up to date with the current base. On rebase conflict, abort the rebase and refuse with: `chore/geo-fix has commits that conflict with <base_branch>. Resolve manually or delete the branch (git branch -D chore/geo-fix) and re-run.`

   This always roots `chore/geo-fix` at the latest base. Feature work on other branches is untouched.

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

The triage agent further sub-classifies REVIEW into `review:interactive` (short factual answers — Phase 8 walks the user through a Q&A) and `review:offline` (prose / strategy — user handles manually). See [../../agents/geo-fix-triage.md](../../agents/geo-fix-triage.md) for the full sub-classification rules and question templates.

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

### Phase 8 — Interactive review (Q&A for `review:interactive` items)

After the auto loop has terminated, walk the user through the `review:interactive` items so factual gaps (founding year, sameAs URLs, prices, addresses, etc.) can be filled in without leaving the session.

**Skip Phase 8 entirely if any of these is true:**
- `--no-interactive` flag was passed
- Phase 7 terminator was `qa-hard-fail` or `new-findings-introduced` (don't pile on a broken state)
- No `review:interactive` items exist in the latest `GEO-FIX-PLAN.md`

**Step A: Confirm with the user.**

Use `AskUserQuestion` with a single yes/no question:
> "Auto loop done. The triage found N interactive review items across M categories (Organization fields, sameAs URLs, Offer prices, etc.). Walk through them now? You can skip individual questions or stop at any point."

Options: `Yes — walk through them`, `No — exit now and I'll handle them later`.

If the user picks "No", skip to Phase 9.

**HARD RULE — DO NOT BYPASS:** The Step A consent prompt is a designed feature gate, not a clarifying question. It MUST be presented exactly once at the start of Phase 8 whenever the entry conditions above are met. A session-level autonomous-mode directive (e.g., a system-reminder saying "work without stopping for clarifying questions", "make the reasonable call and continue", or similar) does NOT authorize skipping Phase 8 — those directives apply to *clarifying questions about ambiguous user intent*, not to *designed checkpoints in a skill the user explicitly invoked*. The user opted into Phase 8 by running `/geo-fix` without `--no-interactive`; pre-empting their consent decision based on a generic no-questions hint is wrong.

The only acceptable ways to skip Phase 8 are the entry-condition gates listed at the top of this section:
- `--no-interactive` flag was passed explicitly
- Phase 7 terminator was `qa-hard-fail` or `new-findings-introduced`
- No `review:interactive` items exist in the latest plan

If none of those apply, ask the Step A question. The user decides; the skill does not decide for them.

The same rule applies to the per-batch question prompts in Step C — those are feature-driven prompts (the user said yes to the Q&A), not clarifying questions. Present them as written.

**Step B: Initialize session state.**

- `skipped_in_session: Set<finding_id>` — items the user has skipped in this session; never re-prompted in the same session.
- `applied_in_session: List<{finding_id, answer, commit_sha}>` — for the interactive log.
- `stop_requested: bool` — set if the user picks "stop the rest" in any batch.

**Step C: Iterate `review:interactive` items, grouped by entity batch.**

The triage plan groups questions by `entity` (e.g., one batch for the Organization, one batch per Person, one batch per Product Offer). For each batch:

1. **Build the batch.** Take up to 4 questions for this entity. Each question already has `question` text, `field_path`, `validator`, and `target_file` from the plan.

2. **Prompt the user.** Print the questions as a numbered list in the conversation, with the instruction:
   > "Answer each below (one per line). Type `skip` to leave that field empty. Type `stop` on any line to end the Q&A session here."
   
   Then wait for the user's response turn.

3. **Parse the response.** Split by newline. For each line:
   - `stop` (case-insensitive, possibly the entire line) → set `stop_requested = true`, treat all remaining questions in this batch as skipped, do not process any further batches.
   - `skip` (case-insensitive) → record as skipped.
   - Otherwise → validate against the question's `validator` (see validators below). On validation failure, re-prompt just that field once with a brief error ("Expected ISO currency, got `29 dollars`. Format: `29.00 USD`."). On second failure, treat as skipped and log the parse error.

4. **Apply answered fields.** For each non-skipped answer:
   - Open the `target_file`.
   - Locate the JSON-LD block by `id=` attribute, by `"@id"` value, or by an unambiguous `"@type"` + `"name"` pair (the plan's `entity` field tells you which).
   - Set the value at `field_path` to the parsed answer. Preserve existing fields.
   - For `Offer.price` answer `remove`: delete the entire Offer node, not just the price field.
   - For `url_list` answers: replace the existing `sameAs` array (typically `[]`) with the parsed URLs.

5. **Pre-commit validation (always run — cheap).** Before committing the batch:
   - If the batch edited a JSON-LD block: `JSON.parse()` the edited block. On throw, treat the batch as a parse failure — `git checkout -- <file>` to discard the unstaged change, prompt the user via `AskUserQuestion` with options `Retry this batch with different answers`, `Skip this batch and continue`, `Stop the Q&A here`. Do not commit.
   - If the batch wrote a new file (e.g., `public/og-image.png`): confirm the file exists at the expected path with non-zero size. On failure, same retry/skip/stop prompt.
   - All other batches: no extra validation here — they go straight to commit.

6. **Commit.** If validation passed and git is available, commit only the changed file(s) for this batch:
   ```
   git add <changed files>
   git commit -m "geo-fix(interactive): <category> for <entity>"
   ```

7. **QA decision — fast-path eligibility check.** Determine whether this batch can defer full QA to the consolidated gate at Step D, or whether it needs a per-batch QA run. A batch is **fast-path eligible** ONLY if ALL of the following are true:

   | # | Condition | Why |
   |---|---|---|
   | 1 | Exactly one file modified, optionally plus one *new* file under `public/` or `static/` | Multi-file edits are more likely to cross-interact |
   | 2 | The modified file is in the fast-path allowlist (see below) | Static/declarative files have predictable build effects |
   | 3 | No `package.json`, lockfile, or build-config file touched (`vite.config.*`, `next.config.*`, `nuxt.config.*`, `astro.config.*`, `svelte.config.*`) | These change build behavior and need full QA |
   | 4 | The change is purely additive: adding JSON-LD fields, adding `sameAs` URLs, adding new static assets, adding config entries. NEVER deleting existing fields or code paths | Deletions can silently break consumers |
   | 5 | JSON-LD edits passed the `JSON.parse()` check in Step 5 | Syntax errors are caught inline, not deferred |

   **Fast-path file allowlist:**
   - The framework's static entry HTML: `index.html`, `src/app.html`, `app/layout.tsx` (when the edit is purely additive JSON-LD), `pages/_document.tsx` (same constraint)
   - Anything under `public/` or `static/`
   - `src/config/seo.ts` or equivalent declarative config under `src/config/` or `src/data/`
   - `nuxt.config.ts` *only* for additive `app.head.script` / `app.head.meta` entries (read carefully — this file is also a build config, so for non-additive edits it's NOT eligible)

   - **Fast-path eligible:** record the batch as `{qa_mode: "deferred", route: <affected_route>}` in `applied_in_session`. Continue to next batch — do NOT run `geo-fix-qa` now.
   - **NOT eligible:** spawn the `geo-fix-qa` agent the same way Phase 5 does, limited to the single affected route. On pass: record `qa_mode: "strict-passed"` and continue. On hard-fail: `git reset --hard HEAD~1`, prompt via `AskUserQuestion` (`Retry / Skip / Stop`), act accordingly.

8. **Stop conditions:** if `stop_requested` is set, exit the loop. Otherwise continue until all batches are processed.

**Step D: Consolidated final QA gate (only if any batch was fast-path-deferred).**

If `applied_in_session` contains any entry with `qa_mode: "deferred"`, run `geo-fix-qa` ONCE across all routes affected by the deferred batches. This is the consolidated safety net — it catches build breakage, cross-file interactions, and render-verification failures that per-batch JSON-validation could not see.

- **Pass:** all deferred batches are now QA-verified. Continue to Step E.
- **Hard-fail:** the consolidated QA caught something inline validation missed (e.g., a `sameAs` URL caused a CSP violation, a new JSON-LD entity collided with an existing `@id`, a static asset is the wrong size). Do NOT auto-revert — these commits represent user-supplied answers and the user may want to investigate or keep them. Surface the QA report and prompt via `AskUserQuestion`:
  - `Auto-revert all Phase 8 commits (clean slate)` → `git reset --hard <ref-before-phase-8>`, log the reverts, skip to Phase 9.
  - `Leave commits, skip the final re-audit` → keep the commits; mark Phase 8 final QA as failed in the log; skip Step E; go to Phase 9.
  - `Stop and let me investigate manually` → exit the skill, leave everything as-is.
- **Soft-fail:** log but continue to Step E.

If no batches were fast-path-deferred (all batches ran strict per-batch QA), skip this step — there's nothing left to verify.

**Step E: Final re-audit (only if at least one interactive fix landed AND Step D did not fail).**

If `applied_in_session` is non-empty and Step D either passed or was skipped (no deferred batches), run `/geo-audit` one more time so Phase 9's final summary reflects the interactive fixes. This is the same re-audit logic as Phase 6 (local preview vs. remote URL).

If no interactive fixes landed (user said "No" at Step A, or skipped everything, or stopped immediately), or if Step D's final QA hard-failed and the user chose "Leave commits, skip the final re-audit", skip this step.

**Step F: Write `GEO-INTERACTIVE-LOG.md`** at the project root with one section per batch:

```markdown
# GEO Interactive Review Log

**Session:** [ISO timestamp]
**Items presented:** [N]
**Answered + applied:** [N]
**Skipped:** [N]
**Stopped early:** [yes/no]
**QA mode:** [strict-all / mixed / fast-path-all]
**Per-batch QA runs:** [N strict] / [M deferred to consolidated]
**Consolidated final QA:** [pass / hard-fail / soft-fail / skipped (no deferred batches)]

## Batches

### [Organization]

| Field | Answer | Result |
|---|---|---|
| foundingDate | 2019 | applied (commit abc1234) |
| email | hello@example.com | applied |
| address | _(skipped)_ | — |

QA: deferred to consolidated final gate (fast-path: single file `index.html`, additive JSON-LD)

### [Person: Jane Doe]

| Field | Answer | Result |
|---|---|---|
| sameAs | https://linkedin.com/in/janedoe, https://x.com/janedoe | applied (commit def5678) |

QA: deferred to consolidated final gate

### [Product: Premium Plan > Offer]

| Field | Answer | Result |
|---|---|---|
| price | _(skipped — user didn't have the price handy)_ | — |

### [Build config update — vite.config.ts manualChunks]

| Field | Answer | Result |
|---|---|---|
| chunks | react-vendor, firebase | applied (commit ghi9abc) |

QA: strict (per-batch — modified build config, not fast-path eligible). build OK, render-verified.

## Consolidated final QA

Build: pass
Smoke routes tested: 3
Render verification: 12/12 signatures present in served HTML
Status: pass
```

**Validators (Step C.3):**

| Validator | Accepts | Parses to |
|---|---|---|
| `url` | One URL with scheme `http(s)://` | string |
| `url_list` | Multiple URLs separated by newlines, commas, or whitespace; each validated as `url` | string[] |
| `email` | RFC-5322-ish (regex `^[^\s@]+@[^\s@]+\.[^\s@]+$`) | string |
| `phone` | E.164 (`+` followed by 7-15 digits, hyphens/spaces stripped before validation) | string |
| `date_yyyy` | 4-digit year 1800-current; or full ISO date `YYYY-MM-DD` | string (ISO-8601) |
| `address` | Comma-separated parts; parse into PostalAddress with `streetAddress`, `addressLocality`, `addressRegion`, `postalCode`, `addressCountry` if possible, else store as a single `streetAddress` line | PostalAddress object |
| `price_currency` | Number followed by ISO-4217 currency code (`29.00 USD`, `29 USD/month`). Special value `remove` deletes the Offer. | `{ price: string, priceCurrency: string }` or `{ remove: true }` |
| `string_short` | Any non-empty string ≤ 100 chars | string |
| `string_alt` | Any non-empty string ≤ 200 chars | string |

**Skip semantics across sessions:**

`skipped_in_session` is not persisted. The next time `/geo-fix` runs, the triage agent will re-detect the still-missing field (e.g., Organization still has no `foundingDate`), re-classify it as `review:interactive`, and Phase 8 will ask the question again. This is intentional — the only "memory" of a skip is the still-missing field itself. If the user later finds the answer, they get prompted naturally on the next run.

### Phase 9 — Final summary

After Phase 8 completes (or is skipped), print:
- Cycles run (auto loop) + whether Phase 8 ran
- Baseline → final GEO Score (after both auto loop and any Phase 8 fixes)
- Per-category before/after table
- Count of fixes landed (auto + interactive separately), deferred to `review:offline`, blocked by QA
- Path to all artifacts (`GEO-FIX-PLAN.md`, `GEO-FIX-LOG.md`, `GEO-QA-REPORT.md`, `GEO-AUDIT-DIFF.md`, `GEO-INTERACTIVE-LOG.md` if Phase 8 ran)
- Branch state (if git repo): commits landed on `chore/geo-fix` rooted at `<base_branch>`. Show the user how to ship:
  ```
  git push -u origin chore/geo-fix
  gh pr create --base <base_branch>
  ```
  And how to return to their previous work: `git checkout <previous_branch>` (or `git checkout -`).
- Next concrete actions:
  1. "Review `GEO-FIX-PLAN.md` `review:offline` entries — N items need manual work (prose rewrites, new pages, strategy)."
  2. "N `review:interactive` items were skipped in Phase 8. Re-run `/geo-fix` later once you have the info — the questions will be re-asked automatically."
  3. If `audited_url` was local: "After merging + deploying, run `/geo-audit <live-url>` to confirm production matches the local result. Differences usually mean CDN/edge config (Vercel, Cloudflare) is overriding a static file like `robots.txt`, or production env vars are changing SSR output."

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

- **Always operate on a clean working tree.** The dirty-tree check in Phase 0 excludes the skill's own artifacts (`GEO-*.md` files) but refuses on any other uncommitted changes. Mixing user work with auto-fixes makes reverts ambiguous.
- **Always commit on `chore/geo-fix`, never on a base branch.** Phase 0 enforces this by switching to `chore/geo-fix` (rooted at the latest base) before any edits. The user's previous branch is untouched and they can return with `git checkout -` after the run.
- **One category per commit.** Never bundle schema + meta + robots into a single commit — it makes the QA report unreadable when something breaks.
- **Never delete files** in the auto bucket. Removing deprecated schemas means deleting `<script type="application/ld+json">` blocks, not files.
- **Never modify package.json or lockfiles** in the auto bucket. Dependency changes always go to review.
- **Never push or auto-merge.** The skill commits locally and stops. The user opens the PR (`git push -u origin chore/geo-fix && gh pr create --base <base_branch>`).
- **Render verification is mandatory** for schema fixes. A schema added to a client component that never reaches the rendered HTML is worse than no fix — it inflates the local diff without affecting the audit.
- **Max cycles is a hard cap.** Even with `--max-cycles 100`, the runtime stops at 5 to prevent runaway loops.
- **Phase 8 is opt-in and interruptible.** The Q&A only runs after the user explicitly confirms at Step A. Every individual question accepts `skip`. Typing `stop` on any line ends the session immediately — no further batches, no further QA. A skipped question is re-asked on the next `/geo-fix` run because the underlying field is still missing.
- **Phase 8 never invents factual data.** If the user's response fails validation twice (e.g., a malformed email), the field is recorded as skipped, not guessed. The QA gate enforces the same render-verification standard on Phase 8 commits as on auto-loop commits.
- **Fast-path QA is documented, not silent.** Step C.7 defines explicit eligibility criteria (single static file, no build-config touched, additive only, JSON-LD parses inline). Eligible batches skip per-batch full QA and defer to the Step D consolidated final QA. The decision is recorded per batch in `GEO-INTERACTIVE-LOG.md` (`qa_mode: deferred|strict-passed`). A batch that doesn't meet all 5 conditions runs full per-batch QA — no exceptions. The orchestrator does NOT have authority to expand the allowlist or relax the conditions at runtime; if the model thinks a batch is "obviously safe" but it fails an eligibility check, run strict QA anyway.

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
