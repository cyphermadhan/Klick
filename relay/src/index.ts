/**
 * Klick Relay — Cloudflare Worker entry point.
 *
 * Routes WebSocket connections to per-channel Durable Objects.
 * URL format: wss://<host>/<channelId>
 *
 * The relay is a dumb encrypted pipe — it forwards binary frames
 * between all connected clients in the same channel room without
 * inspecting or decrypting the content.
 */

export interface Env {
  CHANNEL: DurableObjectNamespace;
  // APNs auth key (base64-encoded .p8 file content) — set via wrangler secret
  APNS_KEY?: string;
  APNS_KEY_ID?: string;
  APNS_TEAM_ID?: string;
  APNS_BUNDLE_ID?: string;
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    const path = url.pathname;

    // Health check
    if (path === "/" || path === "") {
      return new Response(
        JSON.stringify({ status: "ok", service: "klick-relay", version: "1.0.0" }),
        { headers: { "Content-Type": "application/json" } }
      );
    }

    // Push notification registration: POST /register
    if (path === "/register" && request.method === "POST") {
      const body = await request.json() as { channelId: string; token: string; name: string };
      if (!body.channelId || !body.token) {
        return new Response("Missing channelId or token", { status: 400 });
      }
      const id = env.CHANNEL.idFromName(body.channelId);
      const stub = env.CHANNEL.get(id);
      // Forward to Durable Object to store the token
      return stub.fetch(new Request("http://internal/register", {
        method: "POST",
        body: JSON.stringify(body),
      }));
    }

    // Ping offline members: POST /ping
    if (path === "/ping" && request.method === "POST") {
      const body = await request.json() as { channelId: string; senderName: string };
      if (!body.channelId) {
        return new Response("Missing channelId", { status: 400 });
      }
      const id = env.CHANNEL.idFromName(body.channelId);
      const stub = env.CHANNEL.get(id);
      return stub.fetch(new Request("http://internal/ping", {
        method: "POST",
        body: JSON.stringify({ ...body, env: { keyId: env.APNS_KEY_ID, teamId: env.APNS_TEAM_ID, bundleId: env.APNS_BUNDLE_ID, key: env.APNS_KEY } }),
      }));
    }

    // WebSocket channel: /<channelId>
    const channelId = path.slice(1);
    if (!channelId) {
      return new Response("Missing channel ID", { status: 400 });
    }
    const id = env.CHANNEL.idFromName(channelId);
    const stub = env.CHANNEL.get(id);
    return stub.fetch(request);
  },
};

export { ChannelRoom } from "./channel";
