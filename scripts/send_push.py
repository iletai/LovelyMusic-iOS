#!/usr/bin/env python3
"""
LovelyMusic - Push Notification Broadcast CLI
Gửi thông báo đẩy tới toàn bộ thiết bị thông qua Cloudflare Worker APNs Dispatcher.
"""

import argparse
import json
import os
import sys
from typing import Optional
import urllib.request
import urllib.error

DEFAULT_WORKER_URL = "https://your-worker-subdomain.workers.dev"

def send_broadcast_push(
    title: str,
    body: str,
    media_url: Optional[str] = None,
    route: Optional[str] = None,
    browse_id: Optional[str] = None,
    api_key: Optional[str] = None,
    worker_url: Optional[str] = None
):
    target_url = worker_url or os.environ.get("LOVELYMUSIC_WORKER_URL", DEFAULT_WORKER_URL)
    admin_key = api_key or os.environ.get("LOVELYMUSIC_ADMIN_API_KEY")

    if not admin_key:
        print("❌ Lỗi: Cần cung cấp Admin API Key qua tham số --api-key (-k) hoặc biến môi trường LOVELYMUSIC_ADMIN_API_KEY.", file=sys.stderr)
        sys.exit(1)

    endpoint_base = f"{target_url.rstrip('/')}/api/v1/push/broadcast"

    payload: dict = {
        "title": title,
        "body": body
    }
    if media_url:
        payload["mediaUrl"] = media_url
    if route:
        payload["route"] = route
    if browse_id:
        payload["browseId"] = browse_id

    data = json.dumps(payload).encode("utf-8")
    offset = 0
    total_delivered = 0
    total_devices = 0

    while True:
        endpoint = f"{endpoint_base}?limit=50&offset={offset}"
        req = urllib.request.Request(
            endpoint,
            data=data,
            headers={
                "Content-Type": "application/json",
                "User-Agent": "LovelyMusic-Push-CLI/1.0",
                "x-api-key": admin_key
            },
            method="POST"
        )

        try:
            with urllib.request.urlopen(req, timeout=15) as resp:
                result = json.loads(resp.read().decode("utf-8"))
                total_devices = result.get('totalDevices', 0)
                delivered_batch = result.get('deliveredCount', 0)
                total_delivered += delivered_batch
                batched = result.get('batchedCount', 0)

                if not result.get('hasMore', False) or batched == 0:
                    break
                offset += batched
        except urllib.error.HTTPError as e:
            err_msg = e.read().decode("utf-8")
            print(f"❌ Lỗi HTTP {e.code}: {err_msg}", file=sys.stderr)
            sys.exit(1)
        except Exception as e:
            print(f"❌ Lỗi kết nối: {str(e)}", file=sys.stderr)
            sys.exit(1)

    print(f"✅ Gửi hoàn tất! Status: 200")
    print(f"📊 Thống kê: Tổng {total_devices} thiết bị, đã gửi {total_delivered}")
    return {"success": True, "totalDevices": total_devices, "deliveredCount": total_delivered}

def main():
    parser = argparse.ArgumentParser(description="Bắn Push Notification cho LovelyMusic qua Cloudflare Worker")
    parser.add_argument("--title", "-t", required=True, help="Tiêu đề thông báo")
    parser.add_argument("--body", "-b", required=True, help="Nội dung thông báo")
    parser.add_argument("--media-url", "-m", help="URL hình ảnh banner / thumbnail")
    parser.add_argument("--route", "-r", choices=["album", "artist", "playlist", "downloads", "likedSongs"], help="Màn hình đích khi bấm vào thông báo")
    parser.add_argument("--browse-id", "-id", help="Browse ID (nếu route là album, artist, playlist)")
    parser.add_argument("--api-key", "-k", help="Admin API Key (hoặc set env LOVELYMUSIC_ADMIN_API_KEY)")
    parser.add_argument("--worker-url", "-u", help="URL của Cloudflare Worker")

    args = parser.parse_args()
    send_broadcast_push(
        title=args.title,
        body=args.body,
        media_url=args.media_url,
        route=args.route,
        browse_id=args.browse_id,
        api_key=args.api_key,
        worker_url=args.worker_url
    )

if __name__ == "__main__":
    main()
