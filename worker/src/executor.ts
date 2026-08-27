// Read-only tool executor. Serves the agent's search_inbox / get_more / fetch requests from the
// messages already fetched for this scan (the "scan window"). It runs only AFTER
// `authorizeToolCall` has approved a request against merchant scope, so it performs no scope
// checks itself. A Gmail-backed executor that reaches beyond the scan window can replace this by
// implementing the same `ToolExecutor` interface.

import { senderDomain, type MailMetadata } from "./domain/email.ts";
import type { ToolExecutor, ToolMatch } from "./domain/reasoner.ts";

const MATCH_CAP = 12;

function toMatch(meta: MailMetadata): ToolMatch {
  return {
    message_id: meta.id,
    subject: meta.subject,
    sender: meta.sender,
    snippet: meta.snippet,
    received_at: meta.received_at,
  };
}

/** Build an executor scoped to the already-fetched scan window. Pure over its inputs. */
export function createScanExecutor(rawMessages: MailMetadata[]): ToolExecutor {
  const byId = new Map(rawMessages.map((m) => [m.id, m] as const));
  return async (request) => {
    if (request.tool === "fetch") {
      const meta = byId.get(request.message_id);
      if (!meta) return { tool: "fetch", message: null };
      return {
        tool: "fetch",
        message: {
          message_id: meta.id,
          subject: meta.subject,
          sender: meta.sender,
          received_at: meta.received_at,
          // Metadata-only window: the snippet is the available body. A Gmail executor would
          // return the sanitized full body here.
          content: meta.snippet,
        },
      };
    }

    if (request.tool === "get_more") {
      const matches = rawMessages
        .filter((m) => {
          const domain = senderDomain(m.sender);
          return domain === request.sender || domain.endsWith(`.${request.sender}`);
        })
        .slice(0, MATCH_CAP)
        .map(toMatch);
      return { tool: "get_more", matches };
    }

    // search_inbox: keyword match over the scan window.
    const terms = request.query.toLowerCase().split(/\s+/).filter(Boolean);
    const matches = rawMessages
      .filter((m) => {
        const hay = `${m.subject}\n${m.sender}\n${m.snippet}`.toLowerCase();
        return terms.some((t) => hay.includes(t));
      })
      .slice(0, MATCH_CAP)
      .map(toMatch);
    return { tool: "search_inbox", matches };
  };
}
