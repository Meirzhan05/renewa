import { taggedProviderFailure } from "./scan-errors.ts";
import { mustEnv } from "./supabase.ts";

export type Provider = "google" | "microsoft";

export interface StoredTokens {
  access_token: string;
  refresh_token?: string;
  expires_at: number;
  scope?: string;
  token_type?: string;
}

export function tokenExpiresAt(expiresIn: unknown, now = Date.now()): number {
  const seconds = typeof expiresIn === "number" ? expiresIn : Number(expiresIn);
  if (!Number.isFinite(seconds) || seconds <= 0) {
    throw new Error("OAuth provider returned an invalid token expiration.");
  }
  return Math.floor(now / 1000) + Math.floor(seconds);
}

export function callbackURL(): string {
  return `${mustEnv("SUPABASE_URL")}/functions/v1/mail-oauth-callback`;
}

export function authorizationURL(provider: Provider, state: string): string {
  if (provider === "google") {
    const params = new URLSearchParams({
      client_id: mustEnv("GOOGLE_CLIENT_ID"),
      redirect_uri: callbackURL(),
      response_type: "code",
      access_type: "offline",
      prompt: "consent",
      scope: "openid email https://www.googleapis.com/auth/gmail.readonly",
      state,
    });
    return `https://accounts.google.com/o/oauth2/v2/auth?${params}`;
  }
  const params = new URLSearchParams({
    client_id: mustEnv("MICROSOFT_CLIENT_ID"),
    redirect_uri: callbackURL(),
    response_type: "code",
    response_mode: "query",
    scope: "openid email offline_access User.Read Mail.Read",
    state,
  });
  return `https://login.microsoftonline.com/common/oauth2/v2.0/authorize?${params}`;
}

export async function exchangeCode(
  provider: Provider,
  code: string,
): Promise<StoredTokens> {
  const isGoogle = provider === "google";
  const body = new URLSearchParams({
    client_id: mustEnv(isGoogle ? "GOOGLE_CLIENT_ID" : "MICROSOFT_CLIENT_ID"),
    client_secret: mustEnv(
      isGoogle ? "GOOGLE_CLIENT_SECRET" : "MICROSOFT_CLIENT_SECRET",
    ),
    redirect_uri: callbackURL(),
    grant_type: "authorization_code",
    code,
  });
  if (!isGoogle) {
    body.set("scope", "openid email offline_access User.Read Mail.Read");
  }
  const endpoint = isGoogle
    ? "https://oauth2.googleapis.com/token"
    : "https://login.microsoftonline.com/common/oauth2/v2.0/token";
  const response = await fetch(endpoint, { method: "POST", body });
  const payload = await response.json();
  if (!response.ok) {
    throw new Error(
      payload.error_description ?? payload.error ?? "OAuth exchange failed",
    );
  }
  return {
    ...payload,
    expires_at: tokenExpiresAt(payload.expires_in),
  };
}

export async function refreshTokens(
  provider: Provider,
  tokens: StoredTokens,
): Promise<StoredTokens> {
  if (tokens.expires_at > Math.floor(Date.now() / 1000) + 120) return tokens;
  if (!tokens.refresh_token) {
    // Tagged, not prose: this is a genuine authorization failure raised without an HTTP status, and
    // classification must not depend on the word "reconnect" appearing in the sentence.
    throw new Error(
      taggedProviderFailure("authorization", "Mail access expired."),
    );
  }
  const isGoogle = provider === "google";
  const body = new URLSearchParams({
    client_id: mustEnv(isGoogle ? "GOOGLE_CLIENT_ID" : "MICROSOFT_CLIENT_ID"),
    client_secret: mustEnv(
      isGoogle ? "GOOGLE_CLIENT_SECRET" : "MICROSOFT_CLIENT_SECRET",
    ),
    grant_type: "refresh_token",
    refresh_token: tokens.refresh_token,
  });
  if (!isGoogle) {
    body.set("scope", "openid email offline_access User.Read Mail.Read");
  }
  const endpoint = isGoogle
    ? "https://oauth2.googleapis.com/token"
    : "https://login.microsoftonline.com/common/oauth2/v2.0/token";
  const response = await fetch(endpoint, { method: "POST", body });
  const payload = await response.json();
  if (!response.ok) {
    throw new Error(
      payload.error_description ?? payload.error ?? "Token refresh failed",
    );
  }
  return {
    ...tokens,
    ...payload,
    refresh_token: payload.refresh_token ?? tokens.refresh_token,
    expires_at: tokenExpiresAt(payload.expires_in),
  };
}

export async function providerEmail(
  provider: Provider,
  accessToken: string,
): Promise<string | null> {
  const endpoint = provider === "google"
    ? "https://openidconnect.googleapis.com/v1/userinfo"
    : "https://graph.microsoft.com/v1.0/me?$select=mail,userPrincipalName";
  const response = await fetch(endpoint, {
    headers: { Authorization: `Bearer ${accessToken}` },
  });
  if (!response.ok) return null;
  const profile = await response.json();
  return profile.email ?? profile.mail ?? profile.userPrincipalName ?? null;
}
