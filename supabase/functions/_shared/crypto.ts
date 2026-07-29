import { mustEnv } from "./supabase.ts";

function bytesToBase64(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary);
}
function base64ToBytes(value: string): Uint8Array<ArrayBuffer> {
  const decoded = atob(value);
  const buffer = new ArrayBuffer(decoded.length);
  const bytes = new Uint8Array(buffer);
  for (let index = 0; index < decoded.length; index += 1) {
    bytes[index] = decoded.charCodeAt(index);
  }
  return bytes;
}

function encryptionKey(): Promise<CryptoKey> {
  const raw = base64ToBytes(mustEnv("MAIL_TOKEN_ENCRYPTION_KEY"));
  if (raw.byteLength !== 32) {
    throw new Error("MAIL_TOKEN_ENCRYPTION_KEY must decode to 32 bytes");
  }
  return crypto.subtle.importKey("raw", raw, "AES-GCM", false, [
    "encrypt",
    "decrypt",
  ]);
}

export async function encryptJSON(value: unknown): Promise<string> {
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const plaintext = new TextEncoder().encode(JSON.stringify(value));
  const ciphertext = new Uint8Array(
    await crypto.subtle.encrypt(
      { name: "AES-GCM", iv },
      await encryptionKey(),
      plaintext,
    ),
  );
  return `${bytesToBase64(iv)}.${bytesToBase64(ciphertext)}`;
}

export async function decryptJSON<T>(value: string): Promise<T> {
  const [ivPart, ciphertextPart] = value.split(".");
  if (!ivPart || !ciphertextPart) throw new Error("Invalid encrypted token");
  const plaintext = await crypto.subtle.decrypt(
    { name: "AES-GCM", iv: base64ToBytes(ivPart) },
    await encryptionKey(),
    base64ToBytes(ciphertextPart),
  );
  return JSON.parse(new TextDecoder().decode(plaintext)) as T;
}

export async function sha256(value: string): Promise<string> {
  const digest = new Uint8Array(
    await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value)),
  );
  return bytesToBase64(digest);
}
