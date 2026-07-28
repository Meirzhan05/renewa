import { handleOptions, json } from "../_shared/http.ts";
import { adminClient, authenticatedUser } from "../_shared/supabase.ts";

Deno.serve(async (request) => {
  const options = handleOptions(request);
  if (options) return options;

  if (request.method !== "POST") {
    return json({ message: "Method not allowed" }, 405);
  }

  try {
    const user = await authenticatedUser(request);
    const { error } = await adminClient().auth.admin.deleteUser(user.id, false);
    if (error) throw error;
    return json({ deleted: true });
  } catch (error) {
    const message = error instanceof Error ? error.message : "Could not delete account";
    const status = message === "Missing bearer token" || message === "Invalid session" ? 401 : 500;
    return json({ message }, status);
  }
});
