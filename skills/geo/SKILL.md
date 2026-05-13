---
name: geo
description: >
  GEO-first SEO analysis tool. Optimizes websites for AI-powered search engines
  (ChatGPT, Claude, Perplexity, Gemini, Google AI Overviews) while maintaining
  traditional SEO foundations. Performs full GEO audits, citability scoring,
  AI crawler analysis, llms.txt generation, brand mention scanning, platform-specific
  optimization, schema markup, technical SEO, content quality (E-E-A-T), and
  client-ready GEO report generation. Use when user says "geo", "seo", "audit",
  "AI search", "AI visibility", "optimize", "citability", "llms.txt", "schema",
  "brand mentions", "GEO report", or any URL for analysis.
allowed-tools: Read, Grep, Glob, Bash, WebFetch, Write
---

# GEO-SEO Analysis Tool — Claude Code Skill (February 2026)

> **Philosophy:** GEO-first, SEO-supported. AI search is eating traditional search.
> This tool optimizes for where traffic is going, not where it was.

---

## Quick Reference

| Command | What It Does |
|---------|-------------|
| `/geo-audit [<url>]` | Full GEO + SEO audit with parallel subagents. No URL → auto-build + audit local preview. |
| `/geo-fix` | Closed-loop remediation: triage `GEO-AUDIT-REPORT.md`, apply safe auto-fixes, QA, re-audit, loop. |

---

## Market Context (Why GEO Matters)

| Metric | Value | Source |
|--------|-------|--------|
| GEO services market (2025) | $850M-$886M | Yahoo Finance / Superlines |
| Projected GEO market (2031) | $7.3B (34% CAGR) | Industry analysts |
| AI-referred sessions growth | +527% (Jan-May 2025) | SparkToro |
| AI traffic conversion vs organic | 4.4x higher | Industry data |
| Google AI Overviews reach | 1.5B users/month, 200+ countries | Google |
| ChatGPT weekly active users | 900M+ | OpenAI |
| Perplexity monthly queries | 500M+ | Perplexity |
| Gartner: search traffic drop by 2028 | -50% | Gartner |
| Marketers investing in GEO | Only 23% | Industry surveys |
| Brand mentions vs backlinks for AI | 3x stronger correlation | Ahrefs (Dec 2025) |

---

## Orchestration Logic

### Full Audit (`/geo-audit [<url>]`)

**Phase 1: Discovery (Sequential)**
1. Fetch homepage HTML (curl or WebFetch)
2. Detect business type (SaaS, Local, E-commerce, Publisher, Agency, Other)
3. Extract key pages from sitemap.xml or internal links (up to 50 pages)

**Phase 2: Parallel Analysis (Delegate to Subagents)**
Launch these 5 subagents simultaneously:

| Subagent | File | Responsibility |
|----------|------|---------------|
| geo-ai-visibility | `agents/geo-ai-visibility.md` | GEO audit, citability, AI crawlers, llms.txt, brand mentions |
| geo-platform-analysis | `agents/geo-platform-analysis.md` | Platform-specific optimization (ChatGPT, Perplexity, Google AIO) |
| geo-technical | `agents/geo-technical.md` | Technical SEO, Core Web Vitals, crawlability, indexability |
| geo-content | `agents/geo-content.md` | Content quality, E-E-A-T, readability, AI content detection |
| geo-schema | `agents/geo-schema.md` | Schema markup detection, validation, generation |

**Phase 3: Synthesis (Sequential)**
1. Collect all subagent reports
2. Calculate composite GEO Score (0-100)
3. Generate prioritized action plan
4. Output client-ready report

### Scoring Methodology

| Category | Weight | Measured By |
|----------|--------|-------------|
| AI Citability & Visibility | 25% | Passage scoring, answer block quality, AI crawler access |
| Brand Authority Signals | 20% | Mentions on Reddit, YouTube, Wikipedia, LinkedIn; entity presence |
| Content Quality & E-E-A-T | 20% | Expertise signals, original data, author credentials |
| Technical Foundations | 15% | SSR, Core Web Vitals, crawlability, mobile, security |
| Structured Data | 10% | Schema completeness, JSON-LD validation, rich result eligibility |
| Platform Optimization | 10% | Platform-specific readiness (Google AIO, ChatGPT, Perplexity) |

---

## Business Type Detection

Analyze homepage for patterns:

| Type | Signals |
|------|---------|
| **SaaS** | Pricing page, "Sign up", "Free trial", "/app", "/dashboard", API docs |
| **Local Service** | Phone number, address, "Near me", Google Maps embed, service area |
| **E-commerce** | Product pages, cart, "Add to cart", price elements, product schema |
| **Publisher** | Blog, articles, bylines, publication dates, article schema |
| **Agency** | Portfolio, case studies, "Our services", client logos, testimonials |
| **Other** | Default — apply general GEO best practices |

Adjust recommendations based on detected type. Local businesses need LocalBusiness schema and Google Business Profile optimization. SaaS needs SoftwareApplication schema and comparison page strategy. E-commerce needs Product schema and review aggregation.

---

## Skills

| Skill | Directory | Purpose |
|-------|-----------|---------|
| geo-audit | `skills/geo-audit/` | Full audit orchestration and scoring (user-callable: `/geo-audit`) |
| geo-fix | `skills/geo-fix/` | Closed-loop remediation: triage → apply → QA → re-audit (user-callable: `/geo-fix`) |
| geo | `skills/geo/` | Helper assets (this discovery doc, `fetch_page.py`, JSON-LD templates) |

---

## Subagents

The audit spawns 5 analysis agents in parallel. The fix loop uses 2 additional agents.

| Agent | File | Role |
|-------|------|------|
| geo-ai-visibility | `agents/geo-ai-visibility.md` | Audit: citability, AI crawlers, llms.txt, brand mentions |
| geo-platform-analysis | `agents/geo-platform-analysis.md` | Audit: platform-specific (AIO / ChatGPT / Perplexity / Gemini / Bing) |
| geo-technical | `agents/geo-technical.md` | Audit: technical SEO, Core Web Vitals, crawlability |
| geo-content | `agents/geo-content.md` | Audit: E-E-A-T, readability |
| geo-schema | `agents/geo-schema.md` | Audit: structured data |
| geo-fix-triage | `agents/geo-fix-triage.md` | Fix loop: classify findings into auto/review/skip + resolve file targets |
| geo-fix-qa | `agents/geo-fix-qa.md` | Fix loop: build + smoke + render verification |

---

## Output Files

| Command | Output |
|---------|--------|
| `/geo-audit` | `GEO-AUDIT-REPORT.md` in the project's working directory |
| `/geo-fix` | Commits on a `chore/geo-fix` branch + `GEO-FIX-PLAN.md`, `GEO-QA-REPORT.md`, and refreshed `GEO-AUDIT-REPORT.md` per cycle |

---

## Quality Gates

- **Crawl limit:** Max 50 pages per audit (focus on quality over quantity)
- **Timeout:** 30 seconds per page fetch
- **Rate limiting:** 1-second delay between requests, max 5 concurrent
- **Robots.txt:** Always respect, always check
- **Duplicate detection:** Skip pages with >80% content similarity

---

## Quick Start Examples

```
# Audit a live URL
/geo-audit https://example.com

# Audit your local production build (auto-detects framework, builds, serves, audits)
/geo-audit

# After audit: apply safe auto-fixes, re-audit, loop until done
/geo-fix
```
