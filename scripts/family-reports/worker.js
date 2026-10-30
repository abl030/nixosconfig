// family-reports: the Cloudflare Email Worker behind report@barrett-lennard.com
// (nixosconfig #250). Deny by default without losing first contacts:
//
//   approved sender (in the APPROVED KV namespace) -> APPROVED_TO
//   anyone else                                     -> STAGING_TO, plus one
//                                                      "waiting for review" reply
//
// Both destinations are the user's own mailbox (Gmail plus-addresses with
// filters), so every message is read by the user before anything is passed
// on; nothing here reaches Forgejo or an agent. Approve a sender with
// `family-reports approve <address>` on doc1. Deploy with
// scripts/family-reports/deploy.sh. See docs/wiki/services/family-public-site.md.
import { EmailMessage } from "cloudflare:email";

const ADDRESS = "report@barrett-lennard.com";
const REPLY_EVERY = 30 * 24 * 3600; // at most one auto-reply per sender a month

// The bare lowercase address in a header like `Name <a@b>`.
function addressOf(header) {
  if (!header) return "";
  const m = header.match(/<([^>]+)>/);
  return (m ? m[1] : header).trim().toLowerCase();
}

// Never auto-reply to robots, lists or bounces (RFC 3834).
function isAutomated(message, sender) {
  const h = message.headers;
  const auto = (h.get("Auto-Submitted") || "no").toLowerCase();
  const prec = (h.get("Precedence") || "").toLowerCase();
  return (
    auto !== "no" ||
    ["bulk", "list", "junk"].includes(prec) ||
    h.has("List-Id") ||
    h.has("List-Unsubscribe") ||
    sender === "" ||
    /^(mailer-daemon|postmaster|no-?reply|do-?not-?reply|bounces?)[@+-]/.test(sender)
  );
}

function ackReply(message, sender) {
  const subject = (message.headers.get("Subject") || "your message").replace(/[\r\n]+/g, " ");
  const msgId = message.headers.get("Message-ID");
  const lines = [
    `From: Family history <${ADDRESS}>`,
    `To: ${sender}`,
    `Subject: Re: ${subject}`,
    `Message-ID: <${crypto.randomUUID()}@barrett-lennard.com>`,
    `Date: ${new Date().toUTCString()}`,
    "Auto-Submitted: auto-replied",
    "MIME-Version: 1.0",
    "Content-Type: text/plain; charset=utf-8",
  ];
  if (msgId) lines.push(`In-Reply-To: ${msgId}`, `References: ${msgId}`);
  lines.push(
    "",
    "Thank you for writing to the family history site.",
    "",
    "Your message has arrived and is waiting for a person to read it. We read",
    "every message ourselves, so a reply may take a little while.",
    "",
    "https://family.barrett-lennard.com/",
    "",
  );
  return new EmailMessage(ADDRESS, sender, lines.join("\r\n"));
}

export default {
  async email(message, env, ctx) {
    const envelope = (message.from || "").toLowerCase();
    const header = addressOf(message.headers.get("From"));
    const known =
      (envelope && (await env.APPROVED.get(envelope)) !== null) ||
      (header && (await env.APPROVED.get(header)) !== null);

    if (known) {
      await message.forward(env.APPROVED_TO);
      return;
    }

    await message.forward(env.STAGING_TO);

    const sender = header || envelope;
    if (isAutomated(message, sender)) return;
    const key = `replied:${sender}`;
    if ((await env.REPLIES.get(key)) !== null) return;
    try {
      // Cloudflare only lets a reply through to an authenticated sender, so
      // forged senders get no backscatter.
      await message.reply(ackReply(message, sender));
      ctx.waitUntil(env.REPLIES.put(key, "1", { expirationTtl: REPLY_EVERY }));
    } catch (e) {
      console.log(`no auto-reply to ${sender}: ${e}`);
    }
  },
};
