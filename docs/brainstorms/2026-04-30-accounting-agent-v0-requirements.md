---
title: Accounting agent v0 — Beancount + Fava on doc2 + agent in ~/agents
status: ready-to-build
date: 2026-04-30
origin: https://github.com/abl030/nixosconfig/issues/224
---

# Accounting agent v0 — Beancount + Fava on doc2 + agent in ~/agents

## Overview

Stand up Beancount + Fava on doc2 with a private `books` repo on Forgejo as the journal store, plus an `accounting` agent + skill in `~/agents` that mirrors the paperless pattern (thin playbook scaffolded, knowledge accretes through use). v0 ships the full loop together — infra and agent — because the agent is the force multiplier, not an optional follow-up.

The first real workload for the agent is the subdivision backfill: trawl Paperless for subdivision-related docs (surveyor invoices, council fees, demolition, civil works, holding costs) and reconstruct the post-event state of the new lots in Beancount with proper cost-base apportionment. The journal then becomes the source of truth from cut-over forward, and the accountant gets a clean per-property rental schedule each EOFY instead of unrecoverable spreadsheets.

## Problem Frame

The user (and spouse) hand annual rental and subdivision records to an accountant in spreadsheets. Last year's subdivision broke the spreadsheet workflow — cost-base apportionment across the new lots, mid-year holding costs, and capital-vs-revenue distinctions stopped fitting cleanly into rows. Beancount is purpose-built for this kind of multi-property, multi-cost-base, multi-year tracking. With the agent doing data entry from Paperless context, the user gets the structure of double-entry without the friction of typing journal entries themselves.

Issue #224 already ruled out Firefly III, hledger, and the open-core/closed-source options. Beancount is locked. This brainstorm resolves scope, agent shape, and v0 framing for what gets shipped.

## Users

One household: user + spouse. No other actors. No public, no shared write access, no business partners. Accountant is a downstream *consumer* of generated reports at EOFY — not a system user.

## Requirements

- **R1.** `homelab.services.beancount.enable = true;` on doc2 spins up Fava behind `localProxy` at `books.ablz.au` with a valid TLS cert, monitored by Uptime Kuma, dataDir on virtiofs.
- **R2.** Journal lives in a private Forgejo repo at `git.ablz.au/abl030/books`, cloned to the doc2 dataDir at deploy time. Every change to the journal goes through git (commit + push) — git becomes the audit trail.
- **R3.** Fava reads the live journal from the cloned repo on doc2. Pulls happen on-demand (agent commits → pushes → doc2 pulls). Polling cadence settled in planning, not here.
- **R4.** An `accounting` agent lives at `~/agents/.claude/agents/accounting.md` (project-local in the agents repo) with a thin starter playbook covering: (a) chart-of-accounts shape for personal + multi-property, (b) AU residential-rental basics, (c) subdivision cost-base apportionment concepts, (d) the workflow of "read Paperless context → emit Beancount transaction → validate with `bean-check` → commit + push."
- **R5.** A skill at `~/agents/.claude/skills/accounting-update/SKILL.md` mirrors the paperless-triage shape: manual invocation, takes a batch of Paperless docs (or accountant's records for the subdivision backfill) as input, drives the sub-agent to book them, reviews against playbook, commits and pushes the journal.
- **R6.** **Subdivision backfill is the v0 proving workload.** The journal must, by the end of v0 soak, contain the subdivision modelled correctly — original parcel cost base, surveyor/council/demo/civil costs apportioned across the new lots, holding-cost segregation. This is the agent's first big batch of work; it's not deferred and it's not "manual entry as homework." The agent does it through the skill, with the user reviewing.
- **R7.** Property-level structure in the chart of accounts: each rental property gets its own subtree (`Assets:Property:<name>`, `Income:Rental:<name>`, `Expenses:Rental:<name>:*`) so per-property reports for the accountant are one BQL query at EOFY.
- **R8.** Joint household, single journal. Income/expenses booked at the property level (not split by owner). The accountant handles 50/50 (or other-proportion) splitting at return time. If a property is held in non-50/50 proportion, that's noted in the playbook but doesn't change the journal structure.
- **R9.** Paperless integration: when the agent books a transaction, it stores a stable Paperless URL (e.g. `https://paperless.ablz.au/api/documents/<id>/preview/`) in transaction metadata so any line in the journal links back to its source document.
- **R10.** Playbook accretes through use. The starter scaffold is intentionally thin. Like paperless.md grew through actual document classification, accounting.md grows through actual transaction-booking sessions — the user feeds context during sessions, the agent (or the user) curates durable patterns into the playbook.

## Success Criteria

After deploy:
- `https://books.ablz.au` loads with valid TLS, Fava shows the empty/seeded journal, healthz monitor green.
- `git.ablz.au/abl030/books` exists, journal initialized, doc2 cloned and reading.
- `accounting` agent + `accounting-update` skill present in `~/agents`, opening a Claude session there picks both up.
- The agent can take **one** Paperless doc (e.g. a recent rental expense receipt) end-to-end: read it, emit a valid Beancount transaction with Paperless URL metadata, run `bean-check`, commit and push to the books repo, doc2 pulls, Fava shows it. This is the proof-of-loop.

After ~2 weeks of soak (the real test):
- Subdivision is reconstructed in the journal — every cost line either booked into a `Properties:Subdivision-<x>:<lot>` cost-base account or explicitly flagged as "needs accountant input" in playbook scratchpad. No more "lost the plot."
- 5+ ongoing rental transactions booked through the agent. Per-property `bean-query` reports return clean numbers.
- One curated learning has landed in `accounting.md` from real session feedback (matching the paperless pattern).

If all of that holds, v0 has earned the right to v1 (bank-feed integration, EOFY report generation, possibly automated scheduling — those are separate brainstorms).

## Scope Boundaries

In v0:
- Module + journal repo + agent + skill + Fava + the subdivision backfill workload.
- Manual invocation only (`cd ~/agents && claude` then trigger the skill).
- Personal + multi-residential-property scope.
- Plain JSON/markdown reports the agent can generate via BQL on demand.

### Deferred for later

- **Bank feeds** — paperless-driven only in v0. v1 evaluates Up Bank API (if the household banks there), CSV importers via `beangulp`, OFX, or CDR/Basiq.
- **Sole trader / GST / BAS** — not in scope. If the user starts a business with an ABN later, that's a separate brainstorm.
- **Automated scheduled runs** — no nightly timer, no reactive trigger from Paperless tagging. Manual only.
- **EOFY report generation as code** — v0 has BQL queries the agent runs interactively; v1 might wrap them as a "produce accountant pack" skill that emits PDFs/CSVs.
- **Bank-account-level reconciliation** — without bank feeds, there's no second source to reconcile against. v0 trusts Paperless docs as the source.
- **Multi-currency** — assume AUD only. The household has no foreign income/assets in scope.
- **Two-user separation** — single journal, single git identity. Not modelling joint vs separate ownership in the journal — accountant handles at return time.

### Outside this product's identity

- Replacing the accountant. The agent's job is to feed cleaner data to the accountant, not to lodge tax returns or compute final taxable income.
- A general-purpose finance dashboard. This is an accounting journal with rental-property focus, not a budgeting/spending-analysis tool.
- A Paperless replacement for financial document storage. Paperless stays the document store; Beancount stores the transactions that *reference* those documents.

## Key Decisions

- **Both infra and agent ship together in v0.** User explicitly chose this — the agent IS the value, an infra-only v0 would be worthless. Mirrors the paperless deployment pattern (skill + agent landed alongside the service).
- **Full subdivision backfill is the v0 proving workload, not a v1 follow-up.** This is the actual pain being solved. Anything less leaves "lost the plot" unaddressed.
- **Agent + skill mirror the paperless pattern**: thin playbook + manual-trigger skill, accretes through use. No new architectural inventions — known to work.
- **Journal in a Forgejo repo, not in the dataDir directly.** Git is the audit trail; every transaction is a reviewable commit.
- **Fava runs read-only against the cloned repo.** Agent never edits files Fava is serving without going through git.
- **Property-level (not owner-level) accounts.** Accountant splits at return time; complicating the journal structure to model 50/50 ownership upfront is YAGNI.
- **No bank feeds in v0.** Paperless covers the docs that need categorization; bank-feed integration is meaningful work that benefits from knowing the actual transaction patterns first.

## Open Questions

### Resolved during brainstorming

- Platform? → Beancount + Fava (issue #224).
- Scope? → Personal + multi-property, no sole trader, no GST.
- Agent shape? → Separate `accounting` agent + skill in `~/agents`, mirroring paperless pattern.
- Bank feeds? → None in v0.
- Subdivision? → Full backfill in v0, as the agent's first real workload.
- Joint or separate journal? → Joint single journal; accountant splits at EOFY.
- Infra-first or all-together? → All-together. Agent is the value.

### Deferred to planning

- Exact directory structure of the books repo (`accounts/`, `documents/`, `imports/`, etc.).
- Whether Fava runs in a polling-pull mode or post-receive-hook-trigger from Forgejo.
- Specific BQL queries to seed for AU rental-schedule reporting.
- Whether the books repo's Forgejo URL goes via SSH (key already deployed) or HTTPS (no auth wiring needed; agent reads/writes locally and pushes only).

### Deferred indefinitely

- Whether the agent ever lodges a return directly. Not unless the user explicitly takes the accountant out of the loop later — currently outside identity.
- A web-UI for transaction entry. Fava is read-mostly; the agent does writes.

## Sources

- [Issue #224 — self-hosted accounting research](https://github.com/abl030/nixosconfig/issues/224)
- Reference modules in the repo: `modules/nixos/services/forgejo.nix` (single-user service pattern), `modules/nixos/services/paperless.nix` (Paperless-API-aware service)
- Reference agent + skill: `~/agents/.claude/agents/paperless.md`, `~/agents/.claude/skills/paperless-triage/SKILL.md` — the pattern this v0 mirrors
- Brainstorm conversation: 2026-04-30 (this document captures the durable output)
