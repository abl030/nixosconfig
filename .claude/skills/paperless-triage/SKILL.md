---
name: paperless-triage
description: Triage Paperless documents efficiently — haiku sub-agent does the heavy lifting (OCR reading, classification, PATCHes), main agent reviews against the playbook, fixes any slips, and curates concrete learnings into the agent definition. Use when the user asks to triage, classify, or process Paperless documents — "process the inbox", "classify the next N docs", "do these documents", "triage what I just uploaded", or anything pointing at a batch of unclassified Paperless docs by title, ID, or count. Optimises tokens: don't do the classification in the main agent's context, delegate to haiku.
version: 1.0.0
---

# Paperless triage skill

You are the orchestrator. The work splits cleanly:
- **Haiku sub-agent** does per-doc reading, decision-making, and PATCHing. It has the full playbook (`.claude/agents/paperless.md`) and the local sidecar (`.claude/agents/paperless.local.md`).
- **You (main agent)** identify the batch, brief haiku, then review haiku's report, fix any slips by direct PATCH, and curate concrete learnings back into the playbook.

This split saves tokens — the OCR reading and per-doc decisions don't pollute your context — while keeping a quality gate in place.

## Step 1 — Identify the batch

Pick the discovery method based on what the user said:

| User says | Discovery |
|---|---|
| "process the inbox", "do the new ones", "triage what I uploaded" | `GET /api/documents/?is_in_inbox=true&page_size=200&ordering=-added` (Triage tag id 337) |
| "do the next N", "next two/three docs" | `GET /api/documents/?correspondent__isnull=true&page_size=N&ordering=-added` |
| Lists titles/dates from the UI | Fuzzy-find each by `title__icontains=<distinctive substring>` or by date string. Confirm IDs before briefing haiku. |
| Names a specific doc ID | Use it directly, but verify the doc exists and isn't already fully classified |
| "classify everything from <correspondent>" | `correspondent__id=N&document_type__isnull=true` |

Always source the env file first:

```bash
set -a; . /run/secrets/mcp/paperless.env; set +a
AUTH="Authorization: Token $PAPERLESS_TOKEN"
ACCEPT="Accept: application/json; version=9"
```

If the user gave titles from the UI, you may need to look them up to confirm IDs before briefing haiku — quick `jq` over a search response is enough.

## Step 2 — Brief haiku

Spawn the `paperless` sub-agent (it's haiku-backed by definition). Brief shape:

```
Classify <N> documents: [list of IDs and what the user told you about each].

Apply the playbook end-to-end (read sidecar first). Specific guidance for THIS batch:
- <any user-supplied hints — "these are user manuals", "these are Summit VRs", etc.>
- <known doc-type signals from the user list — "BLD####" suggests building approval, "DA form" suggests Application, etc.>
- <correspondent hints — "this is for the <X> loan, account number <Y>" goes in the prompt and gets resolved via the sidecar>

Stop-and-ask cases per the playbook (non-Riverslea correspondent that doesn't exist, ambiguous type, etc.) — keep those in the inbox if they had Triage, list them in your "needs human input" section.

Report ≤350 words. Per doc: id + old title → new title + classification + any flags.
Capture concrete learnings in .claude/agents/paperless.md per the curation directive.
```

**Brief discipline:**
- Don't replicate the playbook in the prompt. Just the batch-specific facts.
- For the inbox path, say so explicitly: "Find docs with `is_in_inbox=true`, classify each, drop the Triage tag in your final PATCH."
- Tell haiku the count of docs you expect — if it returns more or fewer, that's a flag.

## Step 3 — Quality review (the slip checklist)

Run this checklist over every doc haiku touched. Spot-check by re-fetching 1–2 docs at random with `GET /api/documents/<id>/?fields=id,title,correspondent,document_type,storage_path,tags,custom_fields`.

**The slip checklist:**

| Check | What to look for | Fix |
|---|---|---|
| Manual missed pattern | OCR is a manual but correspondent ≠ 145 OR storage_path ≠ 5 | PATCH to correspondent=145, type=74, storage_path=5, tags=[], custom_fields=[] |
| Public ref doc tagged as manual | Gov fact sheet / brochure pinned to correspondent=145 | PATCH to correspondent=null (or the issuing agency), keep storage_path=5 |
| Property tag missing | Doc is at a property storage_path (1/2/3/4) but doesn't have the matching tag (334/333/335/338) | PATCH to add the tag (preserve other tags) |
| Deny-list type used | document_type ∈ {5 Information, 45 summary, 50 Schedule, 47 Confirmation, 2 collection of documents, 63 Employer, 48 recommendations, 1 annual return} | PATCH document_type=null |
| Triage not dropped | Doc has tag 337 but other classification is complete | PATCH tags without 337 |
| Title still has underscores | Title contains `_` | PATCH title with replacements |
| Title has SKU prefix that no human will recognise | e.g. `341_Trampoline_ladder` | PATCH title cleaner |
| Account-bearing doc missing Invoice Number | Bank statement / loan letter without custom field 1 set | PATCH to set the account number from OCR |
| Quote/Invoice missing Amount Due | Has unambiguous total in OCR but custom field 2 not set | PATCH to set Amount Due, citing the OCR line |
| Quote vs Invoice mix-up | Doc says "PROPOSAL" / "QUOTE" but type=Invoice (or vice versa for billable lines) | Per playbook: pre-purchase price offer → Quote (12); payable → Invoice (8) |
| Wrong property | Postal address on letterhead doesn't match asset address — agent picked the wrong storage_path | PATCH per the asset-vs-postal rule |

**Don't re-spawn haiku for fixes.** A direct PATCH from your context is one round-trip; spawning another agent is several.

## Step 3b — Duplicate detection (always present, never auto-delete)

While reviewing haiku's output, watch for duplicate clusters. They show up often:
- **Docusign duplicates** — the same signed doc lands as `Foo.pdf` and `Foo-1.pdf` (and sometimes `Foo-2.pdf`). Same OCR content, same date, same page count.
- **Bifold scans** — front and back of one physical sheet land as two sequential PDFs from the printer (e.g. `..._000458.pdf` and `..._000459.pdf` — one with normal OCR, one with mirrored garbage).
- **Re-uploaded scans** — the user accidentally drops the same file in twice.
- **Email + paper duplicates** — a statement that arrived by email is also archived as a paper scan.

**Detection signals:**
- Identical or near-identical `content_chars` length on docs from the same correspondent + date
- Same `original_file_name` stem with a numeric suffix (`-1`, `-2`)
- Sequential scanner-output filenames in the same minute
- High `more_like_id` similarity — `GET /api/documents/?more_like_id=<id>&page_size=5` returns near-perfect matches

**The rule: always present, never auto-delete.** Even when it's an obvious Docusign duplicate, the user decides. Show them a cluster like:

```
Possible duplicate cluster — Summit Final Colour Selection (6 Feb 2026):
- id 423 — "Summit Final Colour Selection - Riverslea" — canonical, classified earlier
- id 401 — same content, Docusign filename variant
- id 405 — same content, -1 suffix Docusign duplicate

Recommend deleting 401 and 405, keeping 423. Say the word and I'll trash them.
```

The user picks; you DELETE only on explicit confirmation. `DELETE /api/documents/<id>/` returns HTTP 204; in paperless v2+ the doc goes to the trash (`/api/trash/`) where it can be restored or permanently emptied. So delete is reversible — but still, ask first.

**Why ask:**
- The "duplicate" might be the only signed copy and the canonical is the unsigned draft
- One copy might be physically scanned (different metadata) while the other is digital
- The user's filing instinct may be to keep both for audit reasons

Roll dupe-flagging into your normal report's "needs human input" section. Make it easy to spot — page counts, dates, IDs, recommendation. Don't bury it.

## Step 4 — Curate the playbook

Capture only **concrete, reusable** findings. Three buckets:

| Type | Goes in | Examples |
|---|---|---|
| Generic API gotcha or pattern | Public playbook (`.claude/agents/paperless.md`) | "POST /api/X returns 200-not-4xx with null id on duplicate name", "modify_custom_fields requires both add and remove keys", "Docusign produces -1 suffixed duplicates worth deleting" |
| User-specific PII | Local sidecar (`.claude/agents/paperless.local.md`) — gitignored | New addresses, account numbers, family member references, supplier names that would Google-identify the user |
| Doc-family classification pattern | Public playbook, under "Common workflow recipes" | "Vuly Play trampoline manuals all start with vulyplay.com", "Summit VRs are Quotes with Variation Value as Amount Due" |

**What NOT to write:**
- The list of doc IDs you just touched (nothing to learn there)
- A retelling of the user's request
- Anything that would compound over time without being verified — the playbook is already getting long, only add what future-you would thank you for

If haiku already self-curated, READ ITS DIFF before adding more — don't duplicate. Most of haiku's curations are good but occasionally too verbose; trim if so.

## Step 5 — Commit and report

Commit the playbook changes (and any sidecar updates that affect the public file's structure):

```bash
git -C /home/abl030/nixosconfig add .claude/agents/paperless.md
git -C /home/abl030/nixosconfig commit -m "$(cat <<'EOF'
docs(paperless): <one-line summary of what changed in the playbook>

<2–4 lines on what classification work happened, what new patterns were captured.>
EOF
)"
git -C /home/abl030/nixosconfig push
```

Then report to the user:
- Count classified clean vs needed correction
- Any flags requiring their decision (duplicate docs, ambiguous correspondents, etc.)
- One-line summary of what the playbook learned, if anything

Keep the report tight. The user has already seen haiku's report (you got it as a tool result); your job is to surface what's *different* — corrections, flags, deltas.

## Common slips to watch for (compounding history)

These are the patterns haiku has historically slipped on. Pre-check before declaring a batch done:

1. **Manuals classified as `Information` type** — deny-list violation. Manuals are always type=74 (Instruction Manual).
2. **Public reference docs (gov fact sheets) pinned to correspondent=145** — User Manual catch-all is for owner manuals only.
3. **Property tag dropped** when PATCH replaces tags. Always check the new tags array contains the property tag if storage_path is property-bound.
4. **Triage left on after successful classification** — should be dropped.
5. **Underscore titles passed through** — title hygiene exists for a reason; underscores break paperless full-text search.
6. **Bank/loan docs missing Invoice Number custom field** — account number is the asset anchor; it must be captured.
7. **Variation Requests typed as null instead of Quote (12)** — the playbook recipe is explicit; remind haiku in the brief if this batch contains VRs.

## When NOT to use this skill

- The user wants you to look at a single doc and discuss it conversationally — read the OCR yourself, don't spawn haiku for one doc.
- Audit-style work that needs broader reasoning ("what's wrong with my taxonomy", "should I merge these tags?") — use sonnet or do it in main context.
- The user asks about the API itself or wants to debug something — reach for `paperless.md` directly, don't spawn the agent.

## Cost vs accuracy trade-off

Haiku is fast and cheap and follows the playbook well 90% of the time. The 10% slip rate is exactly why this skill exists — the main agent's review is the quality gate. If you find yourself fixing more than half of haiku's PATCHes, the playbook needs tightening (add the rule that's being missed) or the brief needs more specific guidance for that batch.

Don't move the work to sonnet "to be safe" — that defeats the point. Move it to sonnet only when the batch genuinely needs reasoning haiku can't do (ambiguous classifications, taxonomy decisions, OCR quality calls).
