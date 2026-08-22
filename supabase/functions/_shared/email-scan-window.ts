export const initialMailboxLookbackDays = 180;
export const cursorRecoveryLookbackDays = 90;

export function gmailHistoricalQuery(lookbackDays: number): string {
  return `newer_than:${lookbackDays}d`;
}

export function microsoftHistoricalFilter(
  lookbackDays: number,
  now = Date.now(),
): string {
  const start = new Date(now - lookbackDays * 24 * 60 * 60 * 1_000);
  return `receivedDateTime ge ${start.toISOString()}`;
}
