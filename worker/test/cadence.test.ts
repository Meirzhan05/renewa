import { test } from "node:test";
import assert from "node:assert/strict";
import {
  classifyRecurrence,
  computeCadenceFeatures,
  extractAmount,
  reconcileRecurrence,
} from "../src/domain/cadence.ts";
import { parseAssessment, type ToolMatch } from "../src/domain/reasoner.ts";

function tm(partial: Partial<ToolMatch> & { message_id: string }): ToolMatch {
  return {
    subject: "",
    sender: "noreply@example.com",
    snippet: "",
    received_at: "2026-08-01T00:00:00Z",
    ...partial,
  };
}

// Repeated Uber ride receipts: variable amounts, transactional wording, no recurrence language.
const uberRides: ToolMatch[] = [
  tm({ message_id: "u1", sender: "receipts@uber.com", subject: "Your Tuesday trip with Uber", snippet: "Total $12.40", received_at: "2026-08-02T00:00:00Z" }),
  tm({ message_id: "u2", sender: "receipts@uber.com", subject: "Your Friday trip with Uber", snippet: "Total $28.10", received_at: "2026-08-05T00:00:00Z" }),
  tm({ message_id: "u3", sender: "receipts@uber.com", subject: "Your trip with Uber", snippet: "Total $7.65", received_at: "2026-08-09T00:00:00Z" }),
];

// A real subscription: same price every month, explicit membership language.
const netflix: ToolMatch[] = [
  tm({ message_id: "n1", sender: "billing@netflix.com", subject: "Your Netflix receipt", snippet: "Your membership renews — $15.99 monthly", received_at: "2026-07-01T00:00:00Z" }),
];

test("extractAmount parses common money formats", () => {
  assert.equal(extractAmount("Total $12.40"), 12.4);
  assert.equal(extractAmount("Betrag €9,99"), 9.99);
  assert.equal(extractAmount("charged 12.34 USD"), 12.34);
  assert.equal(extractAmount("no money here"), null);
});

test("Uber-style rides read as one-off from cadence features", () => {
  const features = computeCadenceFeatures(uberRides);
  assert.equal(features.amountCount, 3);
  assert.ok(features.relativeSpread >= 0.25, `spread ${features.relativeSpread}`);
  assert.equal(features.hasRecurrenceKeyword, false);
  assert.equal(features.hasTransactionalKeyword, true);
  assert.equal(classifyRecurrence(features).recurrence, "one_off");
});

test("stable repeated amount with membership language reads as recurring", () => {
  assert.equal(classifyRecurrence(computeCadenceFeatures(netflix)).recurrence, "recurring");
});

test("reconcileRecurrence demotes a merchant the model wrongly called a subscription", () => {
  // Model over-eagerly says Uber is an active monthly subscription.
  const model = parseAssessment(
    JSON.stringify({ existence: "high", recurrence: "recurring", amount: 12.4, currency: "USD", billing_cycle: "monthly", confidence: 0.8 }),
    "uber",
    "Uber",
  );
  const reconciled = reconcileRecurrence(model, computeCadenceFeatures(uberRides));
  assert.equal(reconciled.recurrence, "one_off");
  assert.equal(reconciled.existence, "low"); // routes to near-miss, not a false candidate
  assert.equal(reconciled.abstain_reason, "variable_repeated_amounts");
});

test("reconcileRecurrence leaves a genuine subscription intact", () => {
  const model = parseAssessment(
    JSON.stringify({ existence: "high", recurrence: "recurring", amount: 15.99, currency: "USD", billing_cycle: "monthly", confidence: 0.9 }),
    "netflix",
    "Netflix",
  );
  const reconciled = reconcileRecurrence(model, computeCadenceFeatures(netflix));
  assert.equal(reconciled.recurrence, "recurring");
  assert.equal(reconciled.existence, "high");
});
