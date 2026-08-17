import { handleOptions, json } from "../_shared/http.ts";
import { adminClient, authenticatedUser } from "../_shared/supabase.ts";

Deno.serve(async (request) => {
  const options = handleOptions(request);
  if (options) return options;
  if (request.method !== "POST") return json({ message: "Method not allowed" }, 405);

  try {
    const user = await authenticatedUser(request);
    const body = await request.json().catch(() => ({})) as Record<string, unknown>;
    const action = typeof body.action === "string" ? body.action : "status";
    const admin = adminClient();

    switch (action) {
      case "status":
        return json(await status(admin, user.id));
      case "set_preference":
        return json(await setPreference(admin, user.id, body.enabled));
      case "register_device":
        return json(await registerDevice(admin, user.id, body));
      case "disable_device":
        return json(await disableDevice(admin, user.id, body.installation_id));
      case "start_live_activity":
        return json(await startLiveActivity(admin, user.id, body));
      case "end_live_activity":
        return json(await endLiveActivity(admin, user.id, body.activity_id));
      default:
        return json({ message: "Unsupported notification settings action" }, 400);
    }
  } catch (error) {
    const message = error instanceof Error ? error.message : "Notification settings failed";
    const status = message === "Missing bearer token" || message === "Invalid session" ? 401 : 400;
    return json({ message }, status);
  }
});

async function status(admin: ReturnType<typeof adminClient>, userID: string) {
  const { data, error } = await admin.from("notification_preferences")
    .select("inbox_scan_outcomes_enabled")
    .eq("user_id", userID)
    .maybeSingle();
  if (error) throw error;
  return { inbox_scan_outcomes_enabled: data?.inbox_scan_outcomes_enabled ?? false };
}

async function setPreference(admin: ReturnType<typeof adminClient>, userID: string, enabled: unknown) {
  if (typeof enabled !== "boolean") throw new Error("enabled is required");
  const { error } = await admin.from("notification_preferences").upsert({
    user_id: userID,
    inbox_scan_outcomes_enabled: enabled,
  }, { onConflict: "user_id" });
  if (error) throw error;
  return { inbox_scan_outcomes_enabled: enabled };
}

async function registerDevice(
  admin: ReturnType<typeof adminClient>,
  userID: string,
  body: Record<string, unknown>,
) {
  const token = requiredString(body.device_token, "device_token");
  const environment = body.environment === "production" ? "production" : body.environment === "sandbox" ? "sandbox" : null;
  const authorization = ["authorized", "provisional", "denied", "unknown"].includes(String(body.authorization_status))
    ? String(body.authorization_status)
    : "unknown";
  if (!environment) throw new Error("environment is required");
  const { data, error } = await admin.from("notification_device_installations").upsert({
    user_id: userID,
    environment,
    device_token: token,
    authorization_status: authorization,
    is_enabled: authorization === "authorized" || authorization === "provisional",
    disabled_at: null,
    last_seen_at: new Date().toISOString(),
  }, { onConflict: "device_token" }).select("id,is_enabled").single();
  if (error || !data) throw error ?? new Error("Could not register device");
  return { installation_id: data.id, is_enabled: data.is_enabled };
}

async function disableDevice(admin: ReturnType<typeof adminClient>, userID: string, installationID: unknown) {
  const id = requiredString(installationID, "installation_id");
  const { error } = await admin.from("notification_device_installations")
    .update({ is_enabled: false, disabled_at: new Date().toISOString() })
    .eq("id", id)
    .eq("user_id", userID);
  if (error) throw error;
  return { disabled: true };
}

async function startLiveActivity(
  admin: ReturnType<typeof adminClient>,
  userID: string,
  body: Record<string, unknown>,
) {
  const batchID = requiredString(body.batch_id, "batch_id");
  const installationID = requiredString(body.installation_id, "installation_id");
  const activityID = requiredString(body.activity_id, "activity_id");
  const pushToken = requiredString(body.push_token, "push_token");
  const { data: run, error: runError } = await admin.from("email_scan_runs")
    .select("batch_id")
    .eq("user_id", userID)
    .eq("batch_id", batchID)
    .maybeSingle();
  if (runError || !run) throw runError ?? new Error("Scan batch not found");
  const { data: installation, error: installationError } = await admin.from("notification_device_installations")
    .select("id")
    .eq("id", installationID)
    .eq("user_id", userID)
    .eq("is_enabled", true)
    .maybeSingle();
  if (installationError || !installation) throw installationError ?? new Error("Notification device not found");
  const { error } = await admin.from("inbox_scan_live_activities").upsert({
    user_id: userID,
    batch_id: batchID,
    installation_id: installationID,
    activity_id: activityID,
    push_token: pushToken,
    last_stage: "queued",
    last_scanned: 0,
    ended_at: null,
  }, { onConflict: "batch_id,installation_id" });
  if (error) throw error;
  return { registered: true };
}

async function endLiveActivity(admin: ReturnType<typeof adminClient>, userID: string, activityID: unknown) {
  const id = requiredString(activityID, "activity_id");
  const { error } = await admin.from("inbox_scan_live_activities")
    .update({ ended_at: new Date().toISOString() })
    .eq("activity_id", id)
    .eq("user_id", userID);
  if (error) throw error;
  return { ended: true };
}

function requiredString(value: unknown, name: string): string {
  if (typeof value !== "string" || !value.trim()) throw new Error(`${name} is required`);
  return value.trim();
}
