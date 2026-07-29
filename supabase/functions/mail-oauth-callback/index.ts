import { adminClient } from "../_shared/supabase.ts";
import { encryptJSON, sha256 } from "../_shared/crypto.ts";
import { exchangeCode, Provider, providerEmail } from "../_shared/oauth.ts";

Deno.serve(async (request) => {
  const url = new URL(request.url);
  const code = url.searchParams.get("code");
  const state = url.searchParams.get("state");
  const oauthError = url.searchParams.get("error");
  if (oauthError) {
    return Response.redirect(
      `renewa://mail-connected?error=${encodeURIComponent(oauthError)}`,
    );
  }
  if (!code || !state) {
    return new Response("Missing authorization response", { status: 400 });
  }

  try {
    const admin = adminClient();
    const hash = await sha256(state);
    const { data: record, error } = await admin
      .from("oauth_states")
      .select("user_id,provider,expires_at")
      .eq("state_hash", hash)
      .maybeSingle();
    if (error || !record || new Date(record.expires_at) < new Date()) {
      throw new Error("OAuth state expired");
    }
    await admin.from("oauth_states").delete().eq("state_hash", hash);

    const provider = record.provider as Provider;
    const tokens = await exchangeCode(provider, code);
    const email = await providerEmail(provider, tokens.access_token);
    const { error: saveError } = await admin.from("email_connections").upsert({
      user_id: record.user_id,
      provider,
      email,
      encrypted_tokens: await encryptJSON(tokens),
      token_expires_at: new Date(tokens.expires_at * 1000).toISOString(),
      scopes: tokens.scope?.split(" ") ?? [],
      last_error: null,
    }, { onConflict: "user_id,provider" });
    if (saveError) throw saveError;
    return Response.redirect(`renewa://mail-connected?provider=${provider}`);
  } catch (error) {
    const message = error instanceof Error
      ? error.message
      : "Connection failed";
    return Response.redirect(
      `renewa://mail-connected?error=${encodeURIComponent(message)}`,
    );
  }
});
