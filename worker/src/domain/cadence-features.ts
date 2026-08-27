// Numeric cadence *perception* — pure amount/interval/spread math over a merchant's messages, with
// NO verdict and NO keyword judgment. This is the "better eyes" the agent may consult via the
// `compute_cadence` tool; the recurring-vs-one-off *decision* is the model's, never a rule's. It
// deliberately excludes the keyword lists that lived in the old cadence.ts (which are judgment, not
// perception, and are being retired). Pure — no I/O, fully unit-testable.

export type NumericCadence = {
  messageCount: number;
  // Distinct monetary amounts parsed from the evidence, in observed order.
  amounts: number[];
  amountCount: number;
  // (max - min) / median across the observed amounts; 0 when fewer than two amounts. A high spread
  // is evidence of variable one-off purchases; a near-zero spread is evidence of a fixed charge.
  relativeSpread: number;
  // Median gap in days between consecutive messages; null when fewer than two dated messages.
  medianIntervalDays: number | null;
};

/** Parse the first monetary amount from a piece of text, or null. */
export function extractAmount(text: string): number | null {
  // $12.34 / €9,99 / 12.34 USD / ₸ 4500
  const symbol = text.match(/[$€£₸¥]\s?([\d.,]+)/);
  const code = text.match(/([\d.,]+)\s?(?:usd|eur|gbp|kzt|cad|aud|jpy)\b/i);
  const raw = symbol?.[1] ?? code?.[1];
  if (!raw) return null;
  return normalizeAmount(raw);
}

function normalizeAmount(raw: string): number | null {
  let cleaned = raw.trim();
  // Treat a comma as a decimal separator when it is the last group of two digits (European).
  if (/,\d{2}$/.test(cleaned) && !/\.\d/.test(cleaned)) {
    cleaned = cleaned.replace(/\./g, "").replace(",", ".");
  } else {
    cleaned = cleaned.replace(/,/g, "");
  }
  const value = Number(cleaned);
  if (!Number.isFinite(value) || value <= 0) return null;
  return value;
}

export function median(values: number[]): number {
  if (values.length === 0) return 0;
  const sorted = [...values].sort((a, b) => a - b);
  const mid = Math.floor(sorted.length / 2);
  return sorted.length % 2 === 0 ? (sorted[mid - 1]! + sorted[mid]!) / 2 : sorted[mid]!;
}

export type CadenceInput = { subject: string; snippet: string; received_at: string };

/** Derive numeric cadence features from a merchant's messages. Pure perception, no verdict. */
export function computeNumericCadence(messages: CadenceInput[]): NumericCadence {
  const amounts: number[] = [];
  for (const m of messages) {
    const amount = extractAmount(`${m.subject}\n${m.snippet}`);
    if (amount !== null) amounts.push(amount);
  }
  const med = median(amounts);
  const relativeSpread =
    amounts.length >= 2 && med > 0 ? (Math.max(...amounts) - Math.min(...amounts)) / med : 0;

  const times = messages
    .map((m) => Date.parse(m.received_at))
    .filter((t) => Number.isFinite(t))
    .sort((a, b) => a - b);
  let medianIntervalDays: number | null = null;
  if (times.length >= 2) {
    const gaps: number[] = [];
    for (let i = 1; i < times.length; i++) gaps.push((times[i]! - times[i - 1]!) / 86_400_000);
    medianIntervalDays = median(gaps);
  }

  return {
    messageCount: messages.length,
    amounts,
    amountCount: amounts.length,
    relativeSpread,
    medianIntervalDays,
  };
}
