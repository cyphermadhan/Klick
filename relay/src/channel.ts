/**
 * ChannelRoom — Durable Object that manages one channel's WebSocket connections.
 *
 * Protocol:
 * 1. Client connects via WebSocket upgrade.
 * 2. Client sends a JSON text frame: { "type": "join", "name": "DEVICE_NAME" }
 * 3. Server broadcasts updated peer list to all: { "type": "peers", "names": [...] }
 * 4. Client sends binary frames (encrypted Klick packets).
 * 5. Server broadcasts each binary frame to all OTHER clients in the room.
 * 6. On disconnect, server broadcasts updated peer list.
 *
 * The server never inspects binary content — it's end-to-end encrypted
 * with libsodium XSalsa20-Poly1305 at the app layer.
 */

interface Session {
  name: string;
  ws: WebSocket;
}

interface PushToken {
  token: string;
  name: string;
  registeredAt: number;
}

export class ChannelRoom {
  private sessions: Map<WebSocket, Session> = new Map();
  private pushTokens: Map<string, PushToken> = new Map(); // token → PushToken
  private state: DurableObjectState;

  constructor(state: DurableObjectState) {
    this.state = state;
  }

  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);

    // Internal: register push token
    if (url.pathname === "/register" && request.method === "POST") {
      const body = await request.json() as { token: string; name: string };
      this.pushTokens.set(body.token, { token: body.token, name: body.name, registeredAt: Date.now() });
      return new Response(JSON.stringify({ ok: true }), { headers: { "Content-Type": "application/json" } });
    }

    // Internal: ping offline members
    if (url.pathname === "/ping" && request.method === "POST") {
      const body = await request.json() as { senderName: string; env: { keyId?: string; teamId?: string; bundleId?: string; key?: string } };
      const onlineNames = new Set([...this.sessions.values()].map(s => s.name));
      const offlineTokens = [...this.pushTokens.values()].filter(t => !onlineNames.has(t.name));
      // Send push to offline members
      for (const t of offlineTokens) {
        await this.sendPush(t.token, body.senderName, body.env);
      }
      return new Response(JSON.stringify({ pushed: offlineTokens.length }), { headers: { "Content-Type": "application/json" } });
    }

    // Only accept WebSocket upgrades
    const upgradeHeader = request.headers.get("Upgrade");
    if (upgradeHeader !== "websocket") {
      return new Response("Expected WebSocket upgrade", { status: 426 });
    }

    const pair = new WebSocketPair();
    const [client, server] = [pair[0], pair[1]];

    server.accept();
    this.sessions.set(server, { name: "", ws: server });

    server.addEventListener("message", (event: MessageEvent) => {
      if (typeof event.data === "string") {
        this.handleTextMessage(server, event.data);
      } else {
        // Binary frame — broadcast to all others
        this.broadcastBinary(server, event.data as ArrayBuffer);
      }
    });

    server.addEventListener("close", () => {
      this.sessions.delete(server);
      this.broadcastPeerList();
    });

    server.addEventListener("error", () => {
      this.sessions.delete(server);
      this.broadcastPeerList();
    });

    return new Response(null, { status: 101, webSocket: client });
  }

  private handleTextMessage(sender: WebSocket, data: string): void {
    try {
      const msg = JSON.parse(data);
      if (msg.type === "join" && typeof msg.name === "string") {
        const session = this.sessions.get(sender);
        if (session) {
          session.name = msg.name;
          this.broadcastPeerList();
        }
      }
      // Future: handle "ping" for keepalive, "leave" for explicit disconnect
    } catch {
      // Malformed JSON — ignore
    }
  }

  private broadcastBinary(sender: WebSocket, data: ArrayBuffer): void {
    for (const [ws, _] of this.sessions) {
      if (ws !== sender) {
        try {
          ws.send(data);
        } catch {
          // Dead socket — will be cleaned up on close event
        }
      }
    }
  }

  private broadcastPeerList(): void {
    const names = [...this.sessions.values()]
      .map((s) => s.name)
      .filter((n) => n.length > 0);

    const msg = JSON.stringify({ type: "peers", names });

    for (const [ws, _] of this.sessions) {
      try {
        ws.send(msg);
      } catch {
        // Dead socket
      }
    }
  }

  private async sendPush(
    deviceToken: string,
    senderName: string,
    env: { keyId?: string; teamId?: string; bundleId?: string; key?: string }
  ): Promise<void> {
    if (!env.keyId || !env.teamId || !env.bundleId || !env.key) return;

    const payload = JSON.stringify({
      aps: {
        alert: {
          title: "KLICK PTT",
          body: `${senderName} is waiting in the channel`,
        },
        sound: "default",
        "interruption-level": "time-sensitive",
      },
    });

    // JWT for APNs (simplified — in production use a proper JWT lib)
    const header = btoa(JSON.stringify({ alg: "ES256", kid: env.keyId })).replace(/=/g, "");
    const claims = btoa(JSON.stringify({
      iss: env.teamId,
      iat: Math.floor(Date.now() / 1000),
    })).replace(/=/g, "");

    // Note: Full ES256 JWT signing requires crypto.subtle with the .p8 key.
    // For MVP, we'll use a pre-generated token or implement signing later.
    // This is the structure — actual signing needs the imported key.
    const token = `${header}.${claims}.signature_placeholder`;

    try {
      await fetch(`https://api.push.apple.com/3/device/${deviceToken}`, {
        method: "POST",
        headers: {
          "authorization": `bearer ${token}`,
          "apns-topic": env.bundleId,
          "apns-push-type": "alert",
          "apns-priority": "10",
        },
        body: payload,
      });
    } catch {
      // Push failed — non-critical, ignore
    }
  }
}
