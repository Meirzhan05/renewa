// On-demand full-body read executor for the production worker. Unlike the snippet-only
// `createScanReadExecutor`, `fetch` here pulls the message's REAL sanitized body from the Gmail API
// (`format=full`) using the connection's access token — which is what the agent needs to see the
// amount / renewal terms that live in a receipt's body (e.g. Stripe-billed SaaS). Full-body reads
// happen ONLY for the messages the agent explicitly fetches, so it stays the expensive-but-sparing
// tool the budget assumes. `search_inbox` stays metadata-only over the already-triaged window.
//
// Degrade, never abort: on a missing/expired token, a non-2xx response, or a parse error, `fetch`
// falls back to the message snippet — matching the triage/verify/classifier safe-degradation stance.

import { senderDomain, type MailMetadata } from "../domain/email.ts";
import { extractGmailBody, sanitizeBody, type MessagePart } from "../domain/gmail-body.ts";
import type { AgentReadExecutor, AgentReadResult } from "./agent-graph.ts";
import type { ToolMatch } from "./types.ts";

const MATCH_CAP = 12;
const GMAIL_MESSAGE_URL = "https://gmail.googleapis.com/gmail/v1/users/me/messages";

function toMatch(m: MailMetadata): ToolMatch {
  return { message_id: m.id, subject: m.subject, sender: m.sender, snippet: m.snippet, received_at: m.received_at };
}

/**
 * A read executor backed by the live Gmail API. `fetch` returns the sanitized full body of a message
 * already surfaced in this scan; `search_inbox` matches within the triaged window. Bind it with the
 * connection's access token and the scan window (the triaged look-set).
 */
export function createGmailBodyReadExecutor(
  accessToken: string,
  window: MailMetadata[],
): AgentReadExecutor {
  const byId = new Map(window.map((m) => [m.id, m] as const));
  return async (req): Promise<AgentReadResult> => {
    if (req.tool === "fetch") {
      const meta = byId.get(req.message_id);
      if (!meta) return { tool: "fetch", message: null };
      const base = {
        message_id: meta.id,
        subject: meta.subject,
        sender: meta.sender,
        received_at: meta.received_at,
      };
      try {
        // Gmail message ids carry a `gmail-` prefix in the scan window; the API wants the bare id.
        const gmailId = req.message_id.replace(/^gmail-/, "");
        const res = await fetch(`${GMAIL_MESSAGE_URL}/${encodeURIComponent(gmailId)}?format=full`, {
          headers: { Authorization: `Bearer ${accessToken}` },
        });
        if (!res.ok) throw new Error(`gmail_${res.status}`);
        const payload = (await res.json()) as { payload?: MessagePart };
        const body = sanitizeBody(extractGmailBody(payload.payload));
        return { tool: "fetch", message: { ...base, content: body || meta.snippet } };
      } catch {
        // Missing/expired token, network, or parse error → degrade to the snippet, never fail.
        return { tool: "fetch", message: { ...base, content: meta.snippet } };
      }
    }

    // search_inbox: metadata match over the already-triaged window (no full-body reads).
    const terms = req.query.toLowerCase().split(/\s+/).filter(Boolean);
    const matches = window
      .filter((m) => {
        const hay = `${m.subject}\n${m.sender}\n${m.snippet}`.toLowerCase();
        const domain = senderDomain(m.sender);
        return terms.some((t) => hay.includes(t) || domain.includes(t));
      })
      .slice(0, MATCH_CAP)
      .map(toMatch);
    return { tool: "search_inbox", matches };
  };
}
