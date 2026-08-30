import { tasks } from "@trigger.dev/sdk";
import {
  type AnalyzeInboxPagePayload,
  pageAnalysisIdempotencyKey,
  type ScanInboxRunPayload,
  scanRunIdempotencyKey,
} from "./contracts.ts";
import { loadManagedRuntimeConfig } from "./config.ts";

export type ManagedTriggerResult = { id: string };

export type TriggerTask = (
  taskIdentifier: string,
  payload: Record<string, unknown>,
  options: { idempotencyKey: string; concurrencyKey: string },
) => Promise<ManagedTriggerResult>;

export interface ManagedInboxRuntime {
  triggerScanRun(payload: ScanInboxRunPayload): Promise<ManagedTriggerResult>;
  triggerPageAnalysis(payload: AnalyzeInboxPagePayload, userID: string, provider: string): Promise<ManagedTriggerResult>;
}

/**
 * The only application-facing Trigger.dev adapter. Domain and Edge code depend on this interface,
 * not the provider SDK, which keeps a future self-hosted or different runtime replacement local.
 */
export class TriggerManagedInboxRuntime implements ManagedInboxRuntime {
  private readonly triggerTask: TriggerTask;

  constructor(triggerTask: TriggerTask = tasks.trigger as TriggerTask) {
    this.triggerTask = triggerTask;
    loadManagedRuntimeConfig();
  }

  triggerScanRun(payload: ScanInboxRunPayload): Promise<ManagedTriggerResult> {
    return this.triggerTask("scan-inbox-run", payload, {
      idempotencyKey: scanRunIdempotencyKey(payload.scanRunId),
      concurrencyKey: `inbox-run:${payload.connectionId}`,
    });
  }

  triggerPageAnalysis(
    payload: AnalyzeInboxPagePayload,
    userID: string,
    provider: string,
  ): Promise<ManagedTriggerResult> {
    return this.triggerTask("analyze-inbox-page", payload, {
      idempotencyKey: pageAnalysisIdempotencyKey(payload.scanRunId, payload.pageId),
      concurrencyKey: `inbox-page:${provider}:${userID}`,
    });
  }
}
