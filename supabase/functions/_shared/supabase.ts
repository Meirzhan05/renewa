import { createClient, SupabaseClient, User } from "jsr:@supabase/supabase-js@2";

export function adminClient(): SupabaseClient {
  return createClient(
    mustEnv("SUPABASE_URL"),
    platformKey(
      "SUPABASE_SECRET_KEYS",
      "SUPABASE_SECRET_KEY",
      "SUPABASE_SERVICE_ROLE_KEY",
    ),
    { auth: { autoRefreshToken: false, persistSession: false } },
  );
}

export async function authenticatedUser(request: Request): Promise<User> {
  const header = request.headers.get("Authorization");
  if (!header?.startsWith("Bearer ")) throw new Error("Missing bearer token");
  const client = createClient(
    mustEnv("SUPABASE_URL"),
    platformKey(
      "SUPABASE_PUBLISHABLE_KEYS",
      "SUPABASE_PUBLISHABLE_KEY",
      "SUPABASE_ANON_KEY",
    ),
    { global: { headers: { Authorization: header } } },
  );
  const { data, error } = await client.auth.getUser(header.slice(7));
  if (error || !data.user) throw new Error("Invalid session");
  return data.user;
}

export function mustEnv(name: string): string {
  const value = Deno.env.get(name);
  if (!value) throw new Error(`Missing ${name}`);
  return value;
}

function platformKey(
  hostedMapName: string,
  localName: string,
  legacyName: string,
): string {
  const hostedMap = Deno.env.get(hostedMapName);
  if (hostedMap) {
    try {
      const keys = JSON.parse(hostedMap) as Record<string, unknown>;
      const defaultKey = keys.default;
      if (typeof defaultKey === "string" && defaultKey) return defaultKey;
      const firstKey = Object.values(keys).find((value) => typeof value === "string" && value);
      if (typeof firstKey === "string") return firstKey;
    } catch {
      // Fall through to local and legacy key names for self-hosted development.
    }
  }

  const value = Deno.env.get(localName) ?? Deno.env.get(legacyName);
  if (!value) throw new Error(`Missing ${hostedMapName}, ${localName}, or ${legacyName}`);
  return value;
}
