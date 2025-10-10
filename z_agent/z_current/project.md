Awesome—here’s a tight, 4-phase plan to stand up a **standalone Docker Compose stack** for invoices with **Docspell + n8n + Firefly III + invoice2data**. No code yet—just the blueprint and goals.

---

# Phase 1 — Foundation (Compose stack & boundaries)

**Goal:** One self-contained compose stack that boots cleanly and gives you “drop → appears” without AI or external deps.

**Services (single compose file):**

* **Docspell (all-in-one)** — invoice-only DMS inbox (OCR, tags, metadata).
* **Firefly III (core + Data Importer)** — budgets/categories, Bills/Subscriptions, reminders.
* **n8n** — orchestration (webhook in, API out). Telemetry/version checks disabled.
* **invoice2data-worker** — a tiny sidecar you’ll enjoy writing: wraps the invoice2data CLI with a minimal HTTP endpoint (receive PDF → return JSON fields).
* **Postgres** for Docspell & Firefly, **Redis** if needed by Docspell, **Mailpit** (optional) for local email testing, **Caddy** (or your reverse proxy of choice).

**Decisions/Boundaries:**

* **Docspell is invoices-only.** Paperless-ngx remains your long-term docs vault.
* **Zero-AI policy:** no AI nodes/keys; outbound telemetry disabled in n8n.
* **Ingress:**

  * Folder ingest via `dsc watch` on `/invoices` (your “drop” folder).
  * Optional IMAP ingest to bills@… later.
* **Identity/URLs:** `docs.`, `money.`, `flows.`; single `app_net` network; named volumes.

**Exit criteria:**

* `docker compose up` brings everything up.
* Dropping a PDF into `/invoices` makes it visible in Docspell.

---

# Phase 2 — Parsing & data model (invoice2data + mapping)

**Goal:** Extract reliable fields for Firefly with minimal human touch.

**Parsing approach:**

* **invoice2data-worker** receives a file (or Docspell download URL), runs invoice2data templates, responds with:

  * `vendor`, `invoice_number`, `issue_date`, `due_date`, `currency`, `total_gross`, `total_net` (if available), `tax`, `po_number` (if present).

**Data mapping (authoritative fields):**

* **Vendor** → Firefly **payee** (create if missing; maintain vendor→payee map).
* **Total** → Firefly **amount** (expense).
* **Issue/Due** → Firefly **transaction_date** / **bill.due_date**.
* **Invoice #** → Firefly **external_id** (and also a tag); store back in Docspell metadata.
* **Category / Cost center** → Firefly **category** (rule: vendor→category/budget).

**Templates:**

* Start with top 5 vendors; keep templates under git.
* Fallback path: if a doc fails templates, n8n flags it and assigns a “needs review” tag in Docspell.

**Exit criteria:**

* A sample of invoices from your top vendors parse to stable JSON with due dates & totals.

---

# Phase 3 — Orchestration (n8n flow, idempotency, write-back)

**Goal:** Fully automated pipeline: “drop → parsed → in Firefly → reminders,” with robust error handling.

**n8n workflow (high level, no code):**

1. **Trigger:** Docspell webhook “item created” (or tag `bill`).
2. **Fetch:** n8n calls Docspell API → metadata + signed file URL.
3. **Parse:** n8n calls **invoice2data-worker** → receives JSON fields.
4. **Create in Firefly:**

   * Ensure **payee**, **category/budget** exist (create if missing).
   * Create/ensure a **Bill/Subscription** for that vendor (stores due date & cadence if recurring).
   * Create the **expense transaction** linked to the Bill.
5. **Write-back:** Post Firefly IDs (bill + transaction) to Docspell **custom fields/tags** for traceability and **idempotency key** (e.g., file SHA256 + invoice_number).
6. **Notify:**

   * If `due_date <= today+3d`, send email (Mailpit/SMTP) and tag “due-soon”.
   * On parse failure, tag “needs-review” and email a summary.

**Idempotency rules:**

* If a Docspell item already has `firefly_transaction_id` or a matching `(vendor, invoice_number, total)` exists in Firefly, **skip creating** and just update links.

**Exit criteria:**

* End-to-end: dropping a new vendor PDF results in a Firefly bill/transaction within seconds, with Docspell tagged and linked.
* Retries/backoff visible in n8n if something is down.

---

# Phase 4 — Ops, security & polish

**Goal:** Make it boring to run.

**Ops/Hardening:**

* **Backups:** nightly Postgres dumps (Docspell & Firefly) + volume snapshots; test restore.
* **Monitoring:** lightweight healthchecks (container health, n8n failed executions), optional Metabase over Firefly for AP aging & vendor spend.
* **Auth & TLS:** Caddy routes with HTTPS; admin users & strong secrets; n8n encryption key set; tokens in `.env`/secrets.
* **Performance:** enable Docspell async OCR; keep n8n small (no Docker socket mounts); resource limits.
* **Upgrades:** pinned images + periodic `compose pull`; changelog checkboxes in a RUNBOOK.
* **Quality gates:**

  * PR review on new invoice2data templates.
  * Sample fixtures for key vendors to catch regressions.
  * A tiny “smoke” invoice test you can drop to verify the pipeline.

**Exit criteria:**

* Restore test passes.
* Aging & due-soon views in Firefly reflect real data.
* You go a week without touching the plumbing.

---

### That’s the plan

Four phases, clear goals, and everything lives in a **single compose stack**. Next step (when you’re ready): I’ll turn this into a compose file, env scaffolding, and a minimal `invoice2data-worker` skeleton you can flesh out with your vendor templates.

