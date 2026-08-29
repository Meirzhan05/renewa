// Pure Gmail message-body extraction and sanitization. Walks a Gmail `format=full` message payload
// (a MIME tree) into readable text and bounds it for safe use as untrusted model evidence. Shared by
// the worker's on-demand `fetch` executor (src/agent/gmail-read-executor.ts) and the dev Gmail script
// (scripts/gmail-client.ts) so there is exactly ONE sanitizer. No I/O, no googleapis — operates on a
// plain payload object — so it is trivially unit-testable.

/** A Gmail message payload node: a MIME part that may carry body data and/or nested parts. */
export type MessagePart = {
  mimeType?: string | null;
  body?: { data?: string | null } | null;
  parts?: MessagePart[] | null;
};

export function decodeEntities(s: string): string {
  return s
    .replace(/&amp;/g, "&")
    .replace(/&#39;/g, "'")
    .replace(/&quot;/g, '"')
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&nbsp;/g, " ");
}

export function decodeB64Url(data: string): string {
  return Buffer.from(data, "base64url").toString("utf8");
}

export function stripHtml(html: string): string {
  return decodeEntities(
    html.replace(/<(style|script)[\s\S]*?<\/\1>/gi, " ").replace(/<[^>]+>/g, " "),
  );
}

/** Walk the MIME tree for the first part of `mime` that carries data. */
export function partData(payload: MessagePart | undefined, mime: string): string | null {
  const stack: MessagePart[] = payload ? [payload] : [];
  while (stack.length) {
    const p = stack.pop()!;
    if (p.mimeType === mime && p.body?.data) return p.body.data;
    if (p.parts) stack.push(...p.parts);
  }
  return null;
}

/** Prefer text/plain; fall back to stripped text/html; else a single-part text body. */
export function extractGmailBody(payload: MessagePart | undefined): string {
  const plain = partData(payload, "text/plain");
  if (plain) return decodeB64Url(plain);
  const html = partData(payload, "text/html");
  if (html) return stripHtml(decodeB64Url(html));
  if (payload?.body?.data && payload.mimeType?.startsWith("text/")) {
    const text = decodeB64Url(payload.body.data);
    return payload.mimeType === "text/html" ? stripHtml(text) : text;
  }
  return "";
}

/**
 * Sanitize + bound the body: it is untrusted content, so collapse whitespace, drop giant tokens
 * (base64 / tracking blobs), and truncate. The cap keeps a single fetched body well within the
 * agent's token budget.
 */
export function sanitizeBody(text: string): string {
  return text
    .replace(/\r/g, "")
    .replace(/[ \t]+/g, " ")
    .replace(/\n{3,}/g, "\n\n")
    .replace(/\S{200,}/g, "[…]") // strip base64/tracking blobs
    .trim()
    .slice(0, 6000);
}
