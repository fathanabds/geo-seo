# GEO Audit + Fix Skill Bundle

A focused bundle of GEO skills — extracted from [zubair-trabzada/geo-seo-claude](https://github.com/zubair-trabzada/geo-seo-claude). Runs the full `/geo-audit <url>` workflow end-to-end, plus 4 generator skills that turn audit findings into actual fixes.

## What's included

- **1 umbrella entry point** — `skills/geo/SKILL.md`, the discovery doc (`/geo`) that routes users to the right sub-skill based on their goal
- **1 audit orchestrator** — `skills/geo-audit/SKILL.md`, the user-callable command that runs the audit
- **5 analysis agents** — `agents/geo-*.md`, spawned in parallel by the orchestrator
- **4 fix-generator skills** — produce concrete artifacts you can paste into a site:
  - `skills/geo-llmstxt/` — generates a complete `llms.txt` file
  - `skills/geo-schema/` — generates JSON-LD markup snippets
  - `skills/geo-citability/` — returns specific rewrite suggestions for low-citability content
  - `skills/geo-platform-optimizer/` — platform-specific recommendations (AIO / ChatGPT / Perplexity / Gemini / Bing)
- **1 helper script** — `skills/geo/scripts/fetch_page.py`, HTML fetcher used by `geo-schema`
- **6 JSON-LD templates** — `skills/geo/schema/*.json` (Organization, LocalBusiness, Product, SoftwareApplication, Article+Person, WebSite)
- **Python dependencies** — `skills/geo/requirements.txt` (`requests`, `beautifulsoup4`, `lxml`)
- **Installer** — `install.sh` handles copy + venv + path patching

## Layout

```
skills/
├── agents/                              ← lands in ~/.claude/agents/
│   ├── geo-ai-visibility.md             (citability + crawlers + brand + llms.txt)
│   ├── geo-content.md                   (E-E-A-T)
│   ├── geo-platform-analysis.md         (AIO / ChatGPT / Perplexity / Gemini / Bing)
│   ├── geo-schema.md                    (structured data)
│   └── geo-technical.md                 (robots, headers, SSR, security)
├── skills/                              ← lands in ~/.claude/skills/
│   ├── geo-audit/SKILL.md               (orchestrator — triggered by /geo-audit)
│   ├── geo-llmstxt/SKILL.md             (fix: generate llms.txt)
│   ├── geo-schema/SKILL.md              (fix: generate JSON-LD)
│   ├── geo-citability/SKILL.md          (fix: rewrite low-citability content)
│   ├── geo-platform-optimizer/SKILL.md  (fix: per-platform recommendations)
│   └── geo/
│       ├── SKILL.md                     (umbrella entry point — /geo)
│       ├── scripts/fetch_page.py        (HTML fetcher with SSR detection)
│       ├── schema/                      (6 JSON-LD templates)
│       └── requirements.txt
├── install.sh
└── README.md  (this file)
```

## Install

Installs globally into `~/.claude/`, so the skills are available in every project — no per-repo setup.

```bash
curl -sSL https://raw.githubusercontent.com/fathanabds/geo-seo/main/install.sh | bash
```

The script clones this repo to a temp dir, then:

1. Copies `agents/` → `~/.claude/agents/`
2. Copies `skills/` → `~/.claude/skills/`
3. Creates an isolated Python venv at `~/.claude/skills/geo/.venv/`
4. Installs Python deps into the venv (uses `uv` if available, else stdlib `venv` + `pip`)
5. Patches script shebangs + markdown placeholders to point at the new venv
6. Cleans up the temp dir on exit

## Workflow: audit → fix

Not sure where to start? Invoke `/geo` — the umbrella skill is a discovery doc that explains the toolkit and points you at the right sub-command.

**Step 1 — run the audit.** Open Claude Code in the target project and run:

```
/geo-audit https://example.com
```

The audit writes `GEO-AUDIT-REPORT.md` with a composite GEO Score (0-100), critical/high/medium/low issues, and a 30-day action plan.

**Step 2 — fix the findings.** For each issue category in the report, invoke the matching generator skill:

| Audit finding | Fix skill |
|---|---|
| Missing or weak `llms.txt` | `/geo-llmstxt` — generates a complete file from the site |
| Missing or invalid schema markup | `/geo-schema` — generates JSON-LD snippets to paste into pages |
| Low-citability content passages | `/geo-citability` — returns specific rewrite suggestions |
| Platform-specific gaps (AIO / ChatGPT / etc.) | `/geo-platform-optimizer` — targeted recommendations per platform |

Each fix skill produces a concrete artifact (file content, code snippet, or rewrite) — not just analysis.

## What `/geo-audit <url>` does

1. **Phase 1 — Discovery** (orchestrator runs)
   - Fetches the homepage, detects business type, crawls sitemap (up to 50 pages)
2. **Phase 2 — Parallel analysis** (orchestrator spawns 5 agents)
   - Each agent receives the collected page data, returns a category score + findings
3. **Phase 3 — Aggregation** (orchestrator runs)
   - Computes weighted composite GEO Score (0-100)
   - Writes `GEO-AUDIT-REPORT.md` with critical/high/medium/low issues and a 30-day action plan

## What's NOT in this bundle (and why)

The upstream skill ships 15 sub-skills. This bundle includes the 10 you need for audit + remediation. The 5 omitted:

- `geo-crawlers`, `geo-brand-mentions`, `geo-content`, `geo-technical` — analysis-only, fully covered by the 5 audit agents
- `geo-report-pdf`, `geo-proposal`, `geo-compare`, `geo-prospect`, `geo-report`, `geo-update` — business/agency tooling (PDF reports, proposals, monthly compares, CRM)

If you want any of them, install from upstream:

```bash
bash <(curl -sSL https://raw.githubusercontent.com/zubair-trabzada/geo-seo-claude/main/install.sh)
```

## Updating

This bundle is a snapshot. If upstream changes, re-run the install command above — it always pulls the latest from `main`.
