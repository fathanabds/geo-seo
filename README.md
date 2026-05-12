# GEO Audit Skill Bundle

A minimal, portable bundle of the GEO audit skill — extracted from [zubair-trabzada/geo-seo-claude](https://github.com/zubair-trabzada/geo-seo-claude), trimmed to just the pieces needed to run `/geo-audit <url>` end-to-end.

## What's included

- **1 orchestrator skill** — `skills/geo-audit/SKILL.md`, the user-callable command
- **5 analysis agents** — `agents/geo-*.md`, spawned in parallel by the orchestrator
- **1 helper script** — `skills/geo/scripts/fetch_page.py`, for richer HTML parsing (used by `geo-schema`)
- **6 JSON-LD templates** — `skills/geo/schema/*.json` (Organization, LocalBusiness, Product, SoftwareApplication, Article+Person, WebSite) — reference material when implementing audit fixes
- **Python dependencies** — `skills/geo/requirements.txt` (`requests`, `beautifulsoup4`, `lxml`)
- **Installer** — `install.sh` handles copy + venv + path patching

## Layout

```
skills/
├── agents/                          ← lands in ~/.claude/agents/
│   ├── geo-ai-visibility.md         (citability + crawlers + brand + llms.txt)
│   ├── geo-content.md               (E-E-A-T)
│   ├── geo-platform-analysis.md     (AIO / ChatGPT / Perplexity / Gemini / Bing)
│   ├── geo-schema.md                (structured data)
│   └── geo-technical.md             (robots, headers, SSR, security)
├── skills/                          ← lands in ~/.claude/skills/
│   ├── geo-audit/
│   │   └── SKILL.md                 (the orchestrator — triggered by /geo-audit)
│   └── geo/
│       ├── scripts/
│       │   └── fetch_page.py        (HTML fetcher with SSR detection)
│       ├── schema/                  (6 JSON-LD templates — Organization, Product, etc.)
│       └── requirements.txt
├── install.sh
└── README.md  (this file)
```

## Install

Installs globally into `~/.claude/`, so the skill is available in every project — no per-repo setup.

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

Then open Claude Code in any project and run:

```
/geo-audit https://example.com
```

The audit writes `GEO-AUDIT-REPORT.md` to the current working directory.

## What `/geo-audit <url>` does

1. **Phase 1 — Discovery** (orchestrator runs)
   - Fetches the homepage, detects business type, crawls sitemap (up to 50 pages)
2. **Phase 2 — Parallel analysis** (orchestrator spawns 5 agents)
   - Each agent receives the collected page data, returns a category score + findings
3. **Phase 3 — Aggregation** (orchestrator runs)
   - Computes weighted composite GEO Score (0-100)
   - Writes `GEO-AUDIT-REPORT.md` with critical/high/medium/low issues and a 30-day action plan

## What's NOT in this bundle (and why)

The upstream skill ships 15 sub-skills (`geo-citability`, `geo-crawlers`, `geo-llmstxt`, `geo-brand-mentions`, `geo-platform-optimizer`, `geo-content`, `geo-schema`, `geo-technical`, plus business-tier ones like `geo-report-pdf`, `geo-proposal`, `geo-compare`, `geo-prospect`). They're useful but not needed for `/geo-audit` to work — the 5 agents in this bundle cover the same domain.

If you want any of them, install from upstream:
```bash
bash <(curl -sSL https://raw.githubusercontent.com/zubair-trabzada/geo-seo-claude/main/install.sh)
```

## Updating

This bundle is a snapshot. If the upstream agents/orchestrator change, re-extract and re-run `install.sh`.
