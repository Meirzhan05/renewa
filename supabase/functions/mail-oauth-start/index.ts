import { handleOptions, json } from "../_shared/http.ts";
import { adminClient, authenticatedUser } from "../_shared/supabase.ts";
import { sha256 } from "../_shared/crypto.ts";
import { authorizationURL, Provider } from "../_shared/oauth.ts";

Deno.serve(async (request) => {
  const options = handleOptions(request);
  if (options) return options;

  try {
    const user = await authenticatedUser(request);
    const { provider } = await request.json() as { provider: Provider };
    if (!["google", "microsoft"].includes(provider)) return json({ message: "Unsupported provider" }, 400);

    const state = crypto.randomUUID() + crypto.randomUUID();
    const url = authorizationURL(provider, state);
    const admin = adminClient();
    const { error } = await admin.from("oauth_states").insert({
      state_hash: await sha256(state),
      user_id: user.id,
      provider,
      expires_at: new Date(Date.now() + 10 * 60 * 1000).toISOString(),
    });
    if (error) throw error;
    return json({ url });
  } catch (error) {
    const message = error instanceof Error
      ? error.message
      : typeof error === "object" && error !== null && "message" in error && typeof error.message === "string"
      ? error.message
      : "Authorization failed";
    const status = message === "Missing bearer token" || message === "Invalid session"
      ? 401
      : message.startsWith("Missing ")
      ? 503
      : 500;
    return json({ message }, status);
  }
});
