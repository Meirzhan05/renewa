import { handleOptions, json } from "../_shared/http.ts";
import {
  attachInsightProvenance,
  deliverInsightReport,
  insightEvidenceSummary,
  insightOutcomeLog,
  shouldGenerateInsights,
  shouldUseCachedInsight,
  type StoredInsightProvenance,
} from "../_shared/insights-provenance.ts";
import { adminClient, authenticatedUser, mustEnv } from "../_shared/supabase.ts";

type FactSubscription = {
  id: string;
  name: string;
  price: number;
  currency: string;
  billing_cycle: string;
  category: string;
  next_renewal_date: string;
};

type InsightCard = {
  title: string;
  body: string;
  subscription_ids: string[];
  event_ids: string[];
};

type InsightPayload = {
  summary: string;
  cards: InsightCard[];
  generated_at: string;
  is_ai_generated: boolean;
  provenance?: StoredInsightProvenance;
};

Deno.serve(async (request) => {
  const options = handleOptions(request);
  if (options) return options;

  try {
    const user = await authenticatedUser(request);
    const { force = false } = await request.json().catch(() => ({ force: false }));
    const admin = adminClient();
    const [subscriptionsResult, eventsResult, scansResult, snapshotsResult] = await Promise.all([
      admin.from("subscriptions").select("id,name,price,currency,billing_cycle,category,next_renewal_date")
        .eq("user_id", user.id).eq("status", "active").order("next_renewal_date"),
      admin.from("detected_billing_events").select("id,event_type,merchant_name,amount,currency,event_date,renewal_date,confidence")
        .eq("user_id", user.id).gte("created_at", daysAgo(90)).order("created_at", { ascending: false }).limit(40),
      admin.from("email_scan_runs").select("completed_at,events_detected,subscriptions_added,subscriptions_canceled")
        .eq("user_id", user.id).eq("status", "completed").order("completed_at", { ascending: false }).limit(1),
      admin.from("monthly_spend_snapshots").select("period_start,currency,monthly_total,category_totals")
        .eq("user_id", user.id).order("period_start", { ascending: false }).limit(24),
    ]);
    for (const result of [subscriptionsResult, eventsResult, scansResult, snapshotsResult]) {
      if (result.error) throw result.error;
    }

    const subscriptions = (subscriptionsResult.data ?? []) as FactSubscription[];
    if (!shouldGenerateInsights(subscriptions.length)) {
      return json({ report: null, cached: false, fallback: false });
    }

    const events = eventsResult.data ?? [];
    const snapshots = snapshotsResult.data ?? [];
    const facts = buildFacts(subscriptions, events, scansResult.data?.[0] ?? null, snapshots);
    const evidence = insightEvidenceSummary(subscriptions.length, events.length, snapshots.length);
    const fingerprint = await fingerprintFor(facts);
    const now = new Date();
    if (!force) {
      const { data: cached, error } = await admin.from("insight_reports").select("payload")
        .eq("user_id", user.id).eq("fact_fingerprint", fingerprint).gt("expires_at", now.toISOString()).maybeSingle();
      if (error) throw error;
      const cachedPayload = cached?.payload;
      if (shouldUseCachedInsight(force, cachedPayload != null)) {
        const report = deliverInsightReport(cachedPayload as InsightPayload, evidence, true);
        console.info(insightOutcomeLog("cache_hit", evidence));
        return json({
          report,
          cached: true,
          fallback: report.provenance.source === "deterministic",
        });
      }
    }

    let payload: InsightPayload;
    let modelIdentifier: string | null = null;
    try {
      const generated = await generateInsights(facts);
      validatePayload(generated, subscriptions, events);
      payload = attachInsightProvenance(generated, "ai", evidence);
      modelIdentifier = Deno.env.get("DEEPSEEK_MODEL") ?? "deepseek-v4-flash";
      console.info(insightOutcomeLog("ai_generated", evidence));
    } catch (error) {
      const outcome = error instanceof InsightValidationError ? "validation_failed" : "ai_fallback";
      console.warn(insightOutcomeLog(outcome, evidence));
      payload = attachInsightProvenance(deterministicFallback(facts, subscriptions), "deterministic", evidence);
    }

    const expiresAt = new Date(now.getTime() + 24 * 60 * 60 * 1000).toISOString();
    const { error: saveError } = await admin.from("insight_reports").upsert({
      user_id: user.id,
      fact_fingerprint: fingerprint,
      payload,
      model_identifier: modelIdentifier,
      generated_at: now.toISOString(),
      expires_at: expiresAt,
    }, { onConflict: "user_id,fact_fingerprint" });
    if (saveError) throw saveError;
    const report = deliverInsightReport(payload, evidence, false);
    return json({
      report,
      cached: false,
      fallback: report.provenance.source === "deterministic",
    });
  } catch (error) {
    const message = error instanceof Error ? error.message : "Could not refresh insights";
    const status = message === "Missing bearer token" || message === "Invalid session" ? 401 : 500;
    if (status == 401) return json({ message: "Unauthorized" }, status);
    console.error(insightOutcomeLog("request_failed", insightEvidenceSummary(0, 0, 0)));
    return json({ message: "Could not refresh insights" }, status);
  }
});

function buildFacts(subscriptions: FactSubscription[], events: Record<string, unknown>[], latestScan: Record<string, unknown> | null, snapshots: Record<string, unknown>[]) {
  const upcoming = subscriptions.filter((item) => item.next_renewal_date <= dateInDays(30)).slice(0, 12);
  const categories = Object.entries(groupBy(subscriptions, (item) => item.category)).map(([category, values]) => ({
    category,
    subscription_count: values.length,
    currencies: [...new Set(values.map((item) => item.currency))],
  }));
  return { subscriptions, upcoming, categories, recent_events: events, latest_scan: latestScan, snapshots };
}

async function generateInsights(facts: ReturnType<typeof buildFacts>): Promise<InsightPayload> {
  const model = Deno.env.get("DEEPSEEK_MODEL") ?? "deepseek-v4-flash";
  const response = await fetch("https://api.deepseek.com/v1/chat/completions", {
    method: "POST",
    headers: { Authorization: `Bearer ${mustEnv("DEEPSEEK_API_KEY")}`, "Content-Type": "application/json" },
    body: JSON.stringify({
      model,
      thinking: { type: "disabled" },
      max_tokens: 900,
      response_format: { type: "json_object" },
      messages: [
        { role: "system", content: "Use only the supplied structured facts. Never give financial advice or predict prices. Return compact JSON: {summary:string,cards:[{title:string,body:string,subscription_ids:string[],event_ids:string[]}]}. A card must cite at least one supplied id. Never invent amounts, dates, subscriptions, events, or claims." },
        { role: "user", content: JSON.stringify(facts) },
      ],
    }),
  });
  const body = await response.json();
  if (!response.ok) throw new Error(body.error?.message ?? "AI insight request failed");
  const raw = body.choices?.[0]?.message?.content;
  if (!raw) throw new Error("AI returned no insight content");
  const generated = JSON.parse(raw);
  return { summary: generated.summary, cards: generated.cards, generated_at: new Date().toISOString(), is_ai_generated: true };
}

function validatePayload(payload: InsightPayload, subscriptions: FactSubscription[], events: Record<string, unknown>[]) {
  if (typeof payload.summary !== "string" || payload.summary.length < 4 || payload.summary.length > 320 || !Array.isArray(payload.cards)) throw new InsightValidationError();
  const subscriptionIDs = new Set(subscriptions.map((item) => item.id));
  const eventIDs = new Set(events.map((item) => String(item.id)));
  if (payload.cards.length > 3) throw new InsightValidationError();
  for (const card of payload.cards) {
    if (typeof card?.title !== "string" || typeof card?.body !== "string" || card.title.length > 80 || card.body.length > 280) throw new InsightValidationError();
    const subscriptionIDsForCard = Array.isArray(card.subscription_ids) ? card.subscription_ids : [];
    const eventIDsForCard = Array.isArray(card.event_ids) ? card.event_ids : [];
    if (subscriptionIDsForCard.length + eventIDsForCard.length === 0 || !subscriptionIDsForCard.every((id) => subscriptionIDs.has(id)) || !eventIDsForCard.every((id) => eventIDs.has(id))) throw new InsightValidationError();
  }
}

class InsightValidationError extends Error {
  constructor() {
    super("Invalid insight response");
    this.name = "InsightValidationError";
  }
}

function deterministicFallback(facts: ReturnType<typeof buildFacts>, subscriptions: FactSubscription[]): InsightPayload {
  const next = facts.upcoming[0] ?? subscriptions[0];
  return {
    summary: `You have ${subscriptions.length} active subscription${subscriptions.length === 1 ? "" : "s"}. Your next renewal is ${next.name} on ${next.next_renewal_date}.`,
    cards: [{ title: "Next renewal", body: `${next.name} renews on ${next.next_renewal_date}.`, subscription_ids: [next.id], event_ids: [] }],
    generated_at: new Date().toISOString(),
    is_ai_generated: false,
  };
}

function groupBy<T>(values: T[], key: (value: T) => string): Record<string, T[]> {
  return values.reduce<Record<string, T[]>>((result, value) => {
    (result[key(value)] ??= []).push(value);
    return result;
  }, {});
}

async function fingerprintFor(value: unknown): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(JSON.stringify(value)));
  return [...new Uint8Array(digest)].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

function dateInDays(days: number): string {
  const value = new Date();
  value.setUTCDate(value.getUTCDate() + days);
  return value.toISOString().slice(0, 10);
}

function daysAgo(days: number): string {
  return new Date(Date.now() - days * 86_400_000).toISOString();
}
