// Job store for the persistent worker. The graph's *checkpointer* (PostgresSaver) owns run state;
// this store owns the surrounding queue: which scans are pending, the messages to feed a run, the
// open clarifications a run interrupted on, and where finished outcomes are written. The interface
// is what the worker depends on; `PgJobStore` is the Postgres implementation. Splitting them keeps
// the worker loop unit-testable against an in-memory fake.

import type { MailMetadata } from "./domain/email.ts";
import type { RouteOutcome, ClarifyPayload } from "./graph/graph.ts";

export type ScanJob = {
  id: string; // used as the LangGraph thread_id — one checkpoint thread per scan
  userId: string;
  provider: string;
  accessToken: string | null;
  rawMessages: MailMetadata[];
};

// A clarification the run interrupted on, plus the answer once the user provides it.
export type OpenClarification = {
  jobId: string;
  interruptId: string; // LangGraph interrupt id, needed to target the resume
  answer: string;
};

export interface JobStore {
  /** Claim the next pending scan (atomic: marks it 'running'), or null if the queue is empty. */
  claimNextPendingJob(): Promise<ScanJob | null>;
  /** Load a job by id (needed on resume to rebind the executor to its scan window). */
  getJob(jobId: string): Promise<ScanJob | null>;
  /** Persist an interrupted run: mark it awaiting the user and record each clarification asked. */
  markAwaitingUser(jobId: string, payloads: Array<{ interruptId: string; payload: ClarifyPayload }>): Promise<void>;
  /** Answered clarifications ready to resume (user tapped a choice since the last poll). */
  claimAnsweredClarifications(): Promise<OpenClarification[]>;
  /** Mark a clarification fully resolved after its run has been resumed. */
  resolveClarification(clar: OpenClarification): Promise<void>;
  /** Persist the outcomes of a finished run and mark it completed. */
  finishJob(jobId: string, results: RouteOutcome[]): Promise<void>;
  /** Record a run that failed so it is not retried forever. */
  failJob(jobId: string, error: string): Promise<void>;
}

// --- Postgres implementation ---------------------------------------------------------------

import { Pool } from "pg";

export class PgJobStore implements JobStore {
  constructor(private readonly pool: Pool) {}

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
       returning id, user_id, provider, access_token, raw_messages`,
    );
    const row = rows[0];
    if (!row) return null;
    return this.toScanJob(row);
  }

  async getJob(jobId: string): Promise<ScanJob | null> {
    const { rows } = await this.pool.query(
      `select id, user_id, provider, access_token, raw_messages from scan_jobs where id = $1`,
      [jobId],
    );
    const row = rows[0];
    return row ? this.toScanJob(row) : null;
  }

  private toScanJob(row: Record<string, unknown>): ScanJob {
    return {
      id: String(row.id),
      userId: String(row.user_id),
      provider: String(row.provider),
      accessToken: row.access_token ? String(row.access_token) : null,
      rawMessages: Array.isArray(row.raw_messages) ? (row.raw_messages as MailMetadata[]) : [],
    };
  }

  async markAwaitingUser(
    jobId: string,
    payloads: Array<{ interruptId: string; payload: ClarifyPayload }>,
  ): Promise<void> {
    const client = await this.pool.connect();
    try {
      await client.query("begin");
      await client.query(`update scan_jobs set status = 'awaiting_user' where id = $1`, [jobId]);
      for (const { interruptId, payload } of payloads) {
        await client.query(
          `insert into scan_clarifications (job_id, interrupt_id, payload, status)
             values ($1, $2, $3, 'open')
           on conflict (job_id, interrupt_id) do nothing`,
          [jobId, interruptId, payload],
        );
      }
      await client.query("commit");
    } catch (error) {
      await client.query("rollback");
      throw error;
    } finally {
      client.release();
    }
  }

  async claimAnsweredClarifications(): Promise<OpenClarification[]> {
    const { rows } = await this.pool.query(
      `update scan_clarifications
         set status = 'resuming'
       where id in (
         select id from scan_clarifications
          where status = 'answered'
          for update skip locked
          limit 20
       )
       returning job_id, interrupt_id, answer`,
    );
    return rows.map((row) => ({
      jobId: String(row.job_id),
      interruptId: String(row.interrupt_id),
      answer: String(row.answer),
    }));
  }

  async resolveClarification(clar: OpenClarification): Promise<void> {
    await this.pool.query(
      `update scan_clarifications set status = 'resolved', resolved_at = now()
         where job_id = $1 and interrupt_id = $2`,
      [clar.jobId, clar.interruptId],
    );
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
      await client.query(
        `update scan_jobs set status = 'completed', finished_at = now() where id = $1`,
        [jobId],
      );
      await client.query("commit");
    } catch (error) {
      await client.query("rollback");
      throw error;
    } finally {
      client.release();
    }
  }

  async failJob(jobId: string, error: string): Promise<void> {
    await this.pool.query(
      `update scan_jobs set status = 'failed', error = $2, finished_at = now() where id = $1`,
      [jobId, error.slice(0, 500)],
    );
  }
}
