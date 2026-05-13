# GEO Audit + Fix Skill Bundle

A focused bundle of GEO (Generative Engine Optimization) skills. The audit half (`/geo-audit`) is forked from [zubair-trabzada/geo-seo-claude](https://github.com/zubair-trabzada/geo-seo-claude) with local additions (auto-preview mode that builds and audits your project locally when no URL is passed, plus a pre-build safety check that refuses build scripts containing deploy/publish/upload verbs). The fix half (`/geo-fix`) is custom to this repo — a closed-loop remediation skill that applies safe auto-fixes to your frontend project, runs a render-verification QA gate, and re-audits until findings are resolved.

## What's included

- **1 umbrella entry point** — `skills/geo/SKILL.md`, the discovery doc (`/geo`) that explains the toolkit
- **1 audit orchestrator** — `skills/geo-audit/SKILL.md`, the user-callable command that runs the audit
- **1 fix loop** — `skills/geo-fix/SKILL.md`, the closed-loop remediation skill
- **5 analysis agents** — `agents/geo-*.md`, spawned in parallel by the audit
- **2 fix-loop agents** — `agents/geo-fix-triage.md` (classifies findings into auto/review/skip), `agents/geo-fix-qa.md` (build + smoke + render verification)
- **1 helper script** — `skills/geo/scripts/fetch_page.py`, HTML fetcher that preserves `<head>` and JSON-LD (unlike WebFetch)
- **6 JSON-LD templates** — `skills/geo/schema/*.json` (Organization, LocalBusiness, Product, SoftwareApplication, Article+Person, WebSite)
- **Python dependencies** — `skills/geo/requirements.txt` (`requests`, `beautifulsoup4`, `lxml`)
- **Installer** — `install.sh` handles copy + venv + path patching

## Layout

```
agents/                              ← lands in ~/.claude/agents/
├── geo-ai-visibility.md             (citability + crawlers + brand + llms.txt)
├── geo-content.md                   (E-E-A-T)
├── geo-platform-analysis.md         (AIO / ChatGPT / Perplexity / Gemini / Bing)
├── geo-schema.md                    (structured data)
├── geo-technical.md                 (robots, headers, SSR, security)
├── geo-fix-triage.md                (fix loop: classify findings)
└── geo-fix-qa.md                    (fix loop: build + smoke + render verification)
skills/                              ← lands in ~/.claude/skills/
├── geo-audit/SKILL.md               (orchestrator — triggered by /geo-audit)
├── geo-fix/SKILL.md                 (closed-loop remediation — triggered by /geo-fix)
└── geo/
    ├── SKILL.md                     (umbrella entry point — /geo)
    ├── scripts/fetch_page.py        (HTML fetcher with SSR detection)
    ├── schema/                      (6 JSON-LD templates)
    └── requirements.txt
install.sh
README.md  (this file)
```

## Install

Installs globally into `~/.claude/`, so the skills are available in every project — no per-repo setup.

```bash
curl -sSL https://raw.githubusercontent.com/fathanabds/geo-seo/main/install.sh | bash
```

The script clones this repo to a temp dir, then:

1. Copies `agents/` → `~/.claude/agents/`
2. Copies `skills/` → `~/.claude/skills/` (and removes deprecated standalone generator skills from prior installs)
3. Creates an isolated Python venv at `~/.claude/skills/geo/.venv/`
4. Installs Python deps into the venv (uses `uv` if available, else stdlib `venv` + `pip`)
5. Patches script shebangs + markdown placeholders to point at the new venv
6. Cleans up the temp dir on exit

## Workflow: audit → fix → re-audit

**Step 1 — audit your local production build.** Open Claude Code in the target project and run:

```
/geo-audit
```

With no URL, the audit detects your framework, builds the project, starts a local preview server, and audits the rendered HTML. (Pass a URL to audit a live site instead: `/geo-audit https://example.com`.) Writes `GEO-AUDIT-REPORT.md` with a composite GEO Score (0-100), critical/high/medium/low issues, and a 30-day action plan.

**Step 2 — apply auto-safe fixes.** From the same project directory:

```
/geo-fix
```

This reads `GEO-AUDIT-REPORT.md`, classifies each finding into auto/review/skip buckets, applies the auto fixes to a `chore/geo-fix` branch, runs a QA gate (build + smoke + render verification — confirms JSON-LD actually reaches the served HTML, not just source), re-audits, and loops until scores plateau or only review-bucket fixes remain. One category per commit. Never auto-merges; never pushes.

**Step 3 — verify on production.** After you review and merge `chore/geo-fix`, redeploy and run a final audit against the live URL:

```
/geo-audit https://example.com
```

## What `/geo-audit` does

1. **Phase 0 — URL resolution.** If no URL given, detect framework (Next.js, Nuxt, Astro, SvelteKit, Vite+React, plain HTML), build, and serve locally. Pre-flight scans `package.json` build scripts for risky verbs (`deploy`, `publish`, `upload`, etc.) and refuses unless `GEO_FIX_ALLOW_RISKY_BUILD=1` is set.
2. **Phase 1 — Discovery.** Fetch homepage, detect business type, crawl sitemap (up to 50 pages).
3. **Phase 2 — Parallel analysis.** Spawn 5 agents in parallel; each returns a category score (0-100) + findings.
4. **Phase 3 — Aggregation.** Compute weighted composite GEO Score. Write `GEO-AUDIT-REPORT.md`.

**Composite score weighting:** Citability 25%, Brand 20%, E-E-A-T 20%, Technical 15%, Schema 10%, Platform 10%.

## What `/geo-fix` does

A closed-loop remediation skill that reads `GEO-AUDIT-REPORT.md` and iterates until done.

1. **Discovery.** Reads the latest audit report; refuses if missing.
2. **Framework detection.** Detects the same framework set as `/geo-audit`.
3. **Git readiness.** Refuses on a dirty working tree (never auto-stashes — your tree is yours to manage). Switches to a fixed `chore/geo-fix` branch rebased on the base branch.
4. **Triage.** Classifies findings into auto (safe to apply), review (needs human judgment — factual claims, prose rewrites), skip (off-site or architectural).
5. **Apply.** Applies one category per commit. Framework-aware: knows where Organization schema goes in `app/layout.tsx` vs `pages/_document.tsx` vs `nuxt.config.ts` vs `src/app.html` vs `index.html`.
6. **QA gate.** Build → typecheck → lint → start preview server → smoke test routes → **render verification** (confirms each fix appears in the served HTML, not just source — catches the CSR failure mode where JSON-LD in a client component never reaches AI crawlers).
7. **Re-audit + diff.** Re-runs `/geo-audit` against the local preview. Compares scores cycle-over-cycle.
8. **Terminate.** Stops when no auto fixes remain or scores plateau. Prints branch state and instructions to push/PR manually.

Hard rules: never modifies your working tree to satisfy checks; never auto-merges to main; never pushes.

## Updating

This bundle is a snapshot. Re-run the install command above to pull the latest from `main`.
