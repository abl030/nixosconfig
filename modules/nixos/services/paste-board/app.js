"use strict";
// Snippet text is only ever rendered with textContent.
const list = document.getElementById("list");
const status = document.getElementById("status");
let shown = "";

function fmtDur(s) {
  s = Math.max(0, Math.round(s));
  if (s < 60) return s + "s";
  if (s < 3600) return Math.floor(s / 60) + "m";
  return Math.floor(s / 3600) + "h " + Math.floor((s % 3600) / 60) + "m";
}

async function copyText(text, btn) {
  let ok = false;
  try { await navigator.clipboard.writeText(text); ok = true; } catch (e) {
    const ta = document.createElement("textarea");
    ta.value = text; document.body.appendChild(ta); ta.select();
    try { ok = document.execCommand("copy"); } catch (e2) { ok = false; }
    ta.remove();
  }
  btn.textContent = ok ? "Copied ✓" : "Select & Ctrl+C";
  btn.classList.toggle("done", ok);
  setTimeout(() => { btn.textContent = "Copy"; btn.classList.remove("done"); }, 2500);
}

function render(msgs) {
  const now = Date.now() / 1000;
  msgs = msgs.filter(m => m.expires > now).sort((a, b) => b.created - a.created);
  const key = JSON.stringify(msgs.map(m => [m.id, m.created]));
  if (key === shown) { // only refresh the clocks
    document.querySelectorAll(".meta[data-c]").forEach(el => {
      el.textContent = fmtDur(now - el.dataset.c) + " ago · gone in " + fmtDur(el.dataset.e - now);
    });
    return;
  }
  shown = key;
  list.replaceChildren();
  if (!msgs.length) {
    const d = document.createElement("div"); d.className = "empty"; d.textContent = "Nothing here right now.";
    list.appendChild(d); return;
  }
  for (const m of msgs) {
    const card = document.createElement("div"); card.className = "msg";
    const head = document.createElement("div"); head.className = "head";
    const t = document.createElement("div"); t.className = "title"; t.textContent = m.title || "(untitled)";
    const meta = document.createElement("div"); meta.className = "meta";
    meta.dataset.c = m.created; meta.dataset.e = m.expires;
    meta.textContent = fmtDur(now - m.created) + " ago · gone in " + fmtDur(m.expires - now);
    const b = document.createElement("button"); b.type = "button"; b.textContent = "Copy";
    b.addEventListener("click", () => copyText(m.body || "", b));
    head.append(t, meta, b);
    const pre = document.createElement("pre"); pre.textContent = m.body || "";
    card.append(head, pre);
    list.appendChild(card);
  }
}

async function poll() {
  try {
    const r = await fetch("msgs/", { cache: "no-store" });
    const idx = await r.json();
    const files = idx.filter(e => e.type === "file" && /^[A-Za-z0-9_-]+\.json$/.test(e.name));
    const msgs = (await Promise.all(files.map(async e => {
      try {
        const m = await (await fetch("msgs/" + e.name, { cache: "no-store" })).json();
        if (typeof m.created !== "number" || typeof m.expires !== "number") return null;
        m.id = e.name; return m;
      } catch (_) { return null; }
    }))).filter(Boolean);
    render(msgs);
    status.textContent = "";
  } catch (e) {
    status.textContent = "(can't reach the board, retrying…)";
  }
}
poll();
setInterval(poll, 4000);
