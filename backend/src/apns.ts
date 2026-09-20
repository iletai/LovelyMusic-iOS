import { SignJWT, importPKCS8 } from 'jose';
import { D1Database } from './types';

export interface Env {
  DB: D1Database;
  APNS_KEY_ID: string;
  APNS_TEAM_ID: string;
  APNS_PRIVATE_KEY: string;
  APNS_BUNDLE_ID: string;
  APNS_IS_PRODUCTION: string;
  ADMIN_API_KEY: string;
}

let cachedJWT: { token: string; expiresAt: number } | null = null;

export async function getAPNsJWT(env: Env): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  if (cachedJWT && cachedJWT.expiresAt > now + 300) {
    return cachedJWT.token;
  }

  const rawKey = env.APNS_PRIVATE_KEY.replace(/\\n/g, '\n');
  const ecPrivateKey = await importPKCS8(rawKey, 'ES256');
  const token = await new SignJWT({})
    .setProtectedHeader({ alg: 'ES256', kid: env.APNS_KEY_ID })
    .setIssuer(env.APNS_TEAM_ID)
    .setIssuedAt(now)
    .sign(ecPrivateKey);

  cachedJWT = { token, expiresAt: now + 3000 };
  return token;
}

export async function dispatchPush(
  deviceToken: string,
  payload: Record<string, unknown>,
  env: Env
): Promise<{ success: boolean; status: number; reason?: string }> {
  const jwt = await getAPNsJWT(env);
  const host = env.APNS_IS_PRODUCTION === 'true'
    ? 'https://api.push.apple.com'
    : 'https://api.sandbox.push.apple.com';

  const url = `${host}/3/device/${deviceToken}`;
  const response = await fetch(url, {
    method: 'POST',
    headers: {
      'authorization': `bearer ${jwt}`,
      'apns-topic': env.APNS_BUNDLE_ID,
      'apns-push-type': 'alert',
      'apns-priority': '10',
      'apns-expiration': '0',
      'content-type': 'application/json'
    },
    body: JSON.stringify(payload)
  });

  if (response.status === 200) {
    return { success: true, status: 200 };
  }

  const errorData = (await response.json().catch(() => ({}))) as { reason?: string };
  const invalidReasons = ['BadDeviceToken', 'Unregistered', 'DeviceTokenNotForTopic'];
  if (response.status === 410 || (errorData.reason && invalidReasons.includes(errorData.reason))) {
    await env.DB.prepare('UPDATE devices SET is_active = 0, updated_at = ? WHERE device_token = ?')
      .bind(Date.now(), deviceToken)
      .run();
  }

  return { success: false, status: response.status, reason: errorData.reason };
}
