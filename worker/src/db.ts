// Job store for the persistent worker. The graph's *checkpointer* (PostgresSaver) owns run state;
// this store owns the surrounding queue: which scans are pending, the messages to feed a run, and
// where finished outcomes are written. The interface is what the worker depends on; `PgJobStore`
// is the Postgres implementation. Splitting them keeps the worker loop unit-testable against an
// in-memory fake.

import type { MailMetadata } from "./domain/email.ts";
import type { RouteOutcome } from "./graph/graph.ts";
import type { ProposalCandidate } from "./agent/types.ts";

export type ScanJob = {
  id: string; // used as the LangGraph thread_id — one checkpoint thread per scan
  userId: string;
  provider: string;
  accessToken: string | null;
  rawMessages: MailMetadata[];
  // The app-side run this job belongs to. The worker writes its proposals into the app's
  // detected_billing_events → subscription_candidates review queue against this run, then marks the
  // run completed. Null only for legacy/standalone jobs enqueued without an app run.
  scanRunId: string | null;
  batchId: string | null;
};

export interface JobStore {
  /** Claim the next pending scan (atomic: marks it 'running'), or null if the queue is empty. */
  claimNextPendingJob(): Promise<ScanJob | null>;
  /** Claim one known page if it is still pending. Used by managed task executions. */
  claimPendingJob(jobId: string, accessToken?: string): Promise<ScanJob | null>;
  /** Persist the outcomes of a finished run and mark it completed. */
  finishJob(jobId: string, results: RouteOutcome[]): Promise<void>;
  /** Persist an autonomous run's proposals (as scan_outcomes present rows) and mark it completed. */
  finishAutonomousJob(jobId: string, proposals: ProposalCandidate[]): Promise<void>;
  /** Record a run that failed so it is not retried forever. */
  failJob(jobId: string, error: string): Promise<void>;
  /** Return a transiently failed managed page to the durable dispatcher. */
  releaseJobForRetry(jobId: string, error: string): Promise<void>;
  isRunCancellationRequested(scanRunId: string | null): Promise<boolean>;
}

// --- Postgres implementation ---------------------------------------------------------------

import { Pool, type PoolClient } from "pg";

export class PgJobStore implements JobStore {
  private readonly pool: Pool;

  // Note: an explicit field rather than a constructor parameter property — Node's type-stripping
  // runtime (the worker runs TS directly) does not support parameter properties.
  constructor(pool: Pool) {
    this.pool = pool;
  }

  async claimNextPendingJob(): Promise<ScanJob | null> {
    // SKIP LOCKED lets multiple workers pull disjoint jobs without blocking each other.
    const { rows } = await this.pool.query(
      `update scan_jobs
         set status = 'running', started_at = now()
       where id = (
         select id from scan_jobs
          where status = 'pending'
          order by created_at
          for update skip locked
          limit 1
       )
       returning id, user_id, provider, access_token, raw_messages, scan_run_id, batch_id`,
    );
    const row = rows[0];
    if (!row) return null;
    return this.toScanJob(row);
  }

  async claimPendingJob(jobId: string, accessToken?: string): Promise<ScanJob | null> {
    const { rows } = await this.pool.query(
      `update scan_jobs
         set status = 'running', started_at = now()
       where id = $1 and status = 'pending'
       returning id, user_id, provider, access_token, raw_messages, scan_run_id, batch_id`,
      [jobId],
    );
    const row = rows[0];
    const job = row ? this.toScanJob(row) : null;
    // A managed task receives this short-lived credential from the Edge Function at execution
    // time. It is intentionally never written back to scan_jobs or the execution ledger.
    if (job && accessToken) job.accessToken = accessToken;
    return job;
  }

  private toScanJob(row: Record<string, unknown>): ScanJob {
    return {
      id: String(row.id),
      userId: String(row.user_id),
      provider: String(row.provider),
      accessToken: row.access_token ? String(row.access_token) : null,
      rawMessages: Array.isArray(row.raw_messages) ? (row.raw_messages as MailMetadata[]) : [],
      scanRunId: row.scan_run_id ? String(row.scan_run_id) : null,
      batchId: row.batch_id ? String(row.batch_id) : null,
    };
  }

  async finishJob(jobId: string, results: RouteOutcome[]): Promise<void> {
    const client = await this.pool.connect();
    try {
      await client.query("begin");
      for (const outcome of results) {
        await client.query(
          `insert into scan_outcomes (job_id, kind, merchant_key, merchant_name, assessment)
             values ($1, $2, $3, $4, $5)`,
          [
            jobId,
            outcome.kind,
            outcome.assessment.canonical_merchant_key,
            outcome.assessment.merchant_name,
            outcome.assessment,
          ],
        );
      }
      const completion = await client.query(
        `update scan_jobs
            set status = 'completed', finished_at = now()
          where id = $1
          returning scan_run_id`,
        [jobId],
      );
      await this.finalizeLinkedRun(client, completion.rows[0]?.scan_run_id);
      await client.query("commit");
    } catch (error) {
      await client.query("rollback");
      throw error;
    } finally {
      client.release();
    }
  }

  async finishAutonomousJob(jobId: string, proposals: ProposalCandidate[]): Promise<void> {
    // The autonomous funnel produces proposals directly; each is stored as a 'present' outcome (the
    // human-gated confirmation queue is deferred — see change autonomous-inbox-agent, tasks 3.4/3.5).
    const client = await this.pool.connect();
    try {
      await client.query("begin");
      for (const proposal of proposals) {
        await client.query(
          `insert into scan_outcomes (job_id, kind, merchant_key, merchant_name, assessment)
             values ($1, 'present', $2, $3, $4)`,
          [jobId, proposal.merchant_key, proposal.merchant_name, proposal],
        );
      }
      const completion = await client.query(
        `update scan_jobs
            set status = 'completed', finished_at = now()
          where id = $1
          returning scan_run_id`,
        [jobId],
      );
      await this.finalizeLinkedRun(client, completion.rows[0]?.scan_run_id);
      await client.query("commit");
    } catch (error) {
      await client.query("rollback");
      throw error;
    } finally {
      client.release();
    }
  }

  async failJob(jobId: string, error: string): Promise<void> {
    const client = await this.pool.connect();
    try {
      await client.query("begin");
      const completion = await client.query(
        `update scan_jobs
            set status = 'failed', error = $2, finished_at = now()
          where id = $1
          returning scan_run_id`,
        [jobId, error.slice(0, 500)],
      );
      await this.finalizeLinkedRun(client, completion.rows[0]?.scan_run_id);
      await client.query("commit");
    } catch (error) {
      await client.query("rollback");
      throw error;
    } finally {
      client.release();
    }
  }

  async releaseJobForRetry(jobId: string, error: string): Promise<void> {
    await this.pool.query(
      `update scan_jobs
          set status = 'pending', error = $2, started_at = null
        where id = $1 and status = 'running'`,
      [jobId, error.slice(0, 500)],
    );
  }

  async isRunCancellationRequested(scanRunId: string | null): Promise<boolean> {
    if (!scanRunId) return false;
    const { rows } = await this.pool.query(
      "select cancel_requested_at is not null as cancelled from email_scan_runs where id = $1",
      [scanRunId],
    );
    return rows[0]?.cancelled === true;
  }

  private async finalizeLinkedRun(client: PoolClient, scanRunID: unknown): Promise<void> {
    if (typeof scanRunID !== "string" || scanRunID.length === 0) return;
    await client.query("select public.finalize_email_scan_run_if_drained($1)", [scanRunID]);
  }
}
