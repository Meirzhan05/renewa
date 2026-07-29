import { tokenExpiresAt } from "./oauth.ts";

function assert(condition: unknown, message: string): asserts condition {
  if (!condition) throw new Error(message);
}

Deno.test("token expiration accepts positive numeric provider values", () => {
  assert(
    tokenExpiresAt(3_600, 1_700_000_000_000) === 1_700_003_600,
    "Expected a numeric expiry to be accepted.",
  );
  assert(
    tokenExpiresAt("900", 1_700_000_000_000) === 1_700_000_900,
    "Expected a string expiry to be accepted.",
  );
});

Deno.test("token expiration rejects missing or invalid provider values", () => {
  for (const value of [undefined, null, 0, -1, "not-a-number"]) {
    let error: unknown;
    try {
      tokenExpiresAt(value, 1_700_000_000_000);
    } catch (caught) {
      error = caught;
    }
    assert(
      error instanceof Error &&
        error.message ===
          "OAuth provider returned an invalid token expiration.",
      "Expected invalid expiration to be rejected.",
    );
  }
});
