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

    // Apple App Site Association — Universal Links for the iOS app.
    // Must be served over HTTPS, no redirects, Content-Type application/json,
    // and at this exact path with no extension.
    if (path === "/.well-known/apple-app-site-association") {
      return new Response(
        JSON.stringify({
          applinks: {
            details: [
              {
                appIDs: ["6QR7D5NLWL.world.madhans.klick"],
                components: [
                  {
                    "/": "/join",
                    "?": { payload: "?*" },
                    comment: "Klick channel invite",
                  },
                ],
              },
            ],
          },
        }),
        { headers: { "Content-Type": "application/json" } }
      );
    }

    // Fallback page for /join links opened on non-iOS or when the app
    // isn't installed. Universal Links bypass this entirely when the
    // app is installed on iOS.
    if (path === "/join") {
      const html = `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Klick — Channel Invite</title>
<style>
  body { font-family: -apple-system, system-ui, sans-serif; max-width: 480px;
         margin: 48px auto; padding: 0 24px; text-align: center; color: #222; }
  h1 { font-size: 22px; margin-bottom: 8px; }
  p { line-height: 1.5; color: #555; }
  a.btn { display: inline-block; margin-top: 16px; padding: 12px 24px;
          background: #000; color: #fff; text-decoration: none; border-radius: 8px; }
  small { display: block; margin-top: 24px; color: #888; }
</style>
</head>
<body>
<h1>You're invited to a Klick channel</h1>
<p>Klick is an encrypted walkie-talkie for iPhone.</p>
<a class="btn" href="#" id="open">Open in Klick</a>
<small>Don't have Klick yet? Get it from your inviter.</small>
<script>
  // If the app is installed on iOS, the OS opens it via Universal Link
  // before this page even loads. This button is the manual fallback.
  document.getElementById("open").href = location.href;
</script>
</body>
</html>`;
      return new Response(html, {
        headers: { "Content-Type": "text/html; charset=utf-8" },
      });
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
