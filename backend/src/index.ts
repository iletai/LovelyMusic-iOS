import { Env, dispatchPush } from './apns';
import { DeviceRow } from './types';

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const corsHeaders = {
      'Access-Control-Allow-Origin': '*',
      'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
      'Access-Control-Allow-Headers': 'Content-Type, x-api-key, Authorization',
    };

    if (request.method === 'OPTIONS') {
      return new Response(null, { headers: corsHeaders });
    }

    const url = new URL(request.url);
    const json = (data: unknown, status = 200) =>
      new Response(JSON.stringify(data), {
        status,
        headers: { 'content-type': 'application/json', ...corsHeaders }
      });

    if (request.method === 'POST' && url.pathname === '/api/v1/devices/register') {
      const body = (await request.json().catch(() => ({}))) as {
        deviceToken?: string;
        locale?: string;
        appVersion?: string;
        osVersion?: string;
      };

      if (!body.deviceToken || body.deviceToken.length < 64) {
        return json({ error: 'Invalid deviceToken' }, 400);
      }

      const now = Date.now();
      await env.DB.prepare(`
        INSERT INTO devices (device_token, locale, app_version, os_version, is_active, created_at, updated_at)
        VALUES (?, ?, ?, ?, 1, ?, ?)
        ON CONFLICT(device_token) DO UPDATE SET
          locale = excluded.locale,
          app_version = excluded.app_version,
          os_version = excluded.os_version,
          is_active = 1,
          updated_at = excluded.updated_at
      `).bind(
        body.deviceToken,
        body.locale ?? 'vi_VN',
        body.appVersion ?? '1.0.0',
        body.osVersion ?? '18.0',
        now,
        now
      ).run();

      return json({ success: true, message: 'Device registered successfully' });
    }

    if (request.method === 'POST' && url.pathname === '/api/v1/devices/unregister') {
      const body = (await request.json().catch(() => ({}))) as { deviceToken?: string };
      if (!body.deviceToken) {
        return json({ error: 'deviceToken required' }, 400);
      }
      await env.DB.prepare('UPDATE devices SET is_active = 0, updated_at = ? WHERE device_token = ?')
        .bind(Date.now(), body.deviceToken)
        .run();
      return json({ success: true, message: 'Device deactivated' });
    }

    if (request.method === 'POST' && url.pathname === '/api/v1/push/broadcast') {
      const apiKey = request.headers.get('x-api-key');
      if (apiKey !== env.ADMIN_API_KEY) {
        return json({ error: 'Unauthorized' }, 401);
      }

      const body = (await request.json().catch(() => ({}))) as {
        title?: string;
        body?: string;
        mediaUrl?: string;
        route?: string;
        browseId?: string;
      };

      if (!body.title || !body.body) {
        return json({ error: 'title and body are required' }, 400);
      }

      const payload = {
        aps: {
          alert: {
            title: body.title,
            body: body.body
          },
          badge: 1,
          sound: 'default',
          'mutable-content': 1
        },
        media_url: body.mediaUrl,
        route: body.route,
        browse_id: body.browseId
      };

      const limitParam = parseInt(url.searchParams.get('limit') ?? '50', 10);
      const offsetParam = parseInt(url.searchParams.get('offset') ?? '0', 10);
      const safeLimit = Math.min(Math.max(1, limitParam), 50); // Cap at 50 to respect Cloudflare Worker subrequest limit

      const countResult = await env.DB.prepare(
        'SELECT COUNT(*) as total FROM devices WHERE is_active = 1'
      ).all<{ total: number }>();
      const totalActiveDevices = countResult.results?.[0]?.total ?? 0;

      const result = await env.DB.prepare(
        'SELECT device_token FROM devices WHERE is_active = 1 LIMIT ? OFFSET ?'
      ).bind(safeLimit, offsetParam).all<DeviceRow>();

      const tokens = result.results?.map((r: DeviceRow) => r.device_token) ?? [];
      const outcomes = await Promise.allSettled(
        tokens.map((token: string) => dispatchPush(token, payload, env))
      );
      const delivered = outcomes.filter(
        (o: PromiseSettledResult<{ success: boolean }>) => o.status === 'fulfilled' && o.value.success
      ).length;

      return json({
        success: delivered > 0 || tokens.length === 0,
        totalDevices: totalActiveDevices,
        batchedCount: tokens.length,
        deliveredCount: delivered,
        offset: offsetParam,
        limit: safeLimit,
        hasMore: offsetParam + tokens.length < totalActiveDevices
      });
    }

    return json({ error: 'Not Found' }, 404);
  }
};
