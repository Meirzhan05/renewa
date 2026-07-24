import { createClient, SupabaseClient, User } from "jsr:@supabase/supabase-js@2";

export function adminClient(): SupabaseClient {
  return createClient(
    mustEnv("SUPABASE_URL"),
    envEither("SUPABASE_SECRET_KEY", "SUPABASE_SERVICE_ROLE_KEY"),
    { auth: { autoRefreshToken: false, persistSession: false } },
  );
}

export async function authenticatedUser(request: Request): Promise<User> {
  const header = request.headers.get("Authorization");
  if (!header?.startsWith("Bearer ")) throw new Error("Missing bearer token");
  const client = createClient(
    mustEnv("SUPABASE_URL"),
    envEither("SUPABASE_PUBLISHABLE_KEY", "SUPABASE_ANON_KEY"),
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

function envEither(primary: string, fallback: string): string {
  const value = Deno.env.get(primary) ?? Deno.env.get(fallback);
  if (!value) throw new Error(`Missing ${primary} or ${fallback}`);
  return value;
}
