import type { PairSocket, SocketFactory } from "../../src/services/syncPairing.ts";

/**
 * Le relais d'appairage en mémoire, avec les règles de relay/src/index.ts : un salon par nom de
 * canal, les messages `pair` (≤ 4 Ko) sont transmis aux autres sockets du salon avec `from`, et
 * rien n'est gardé. `log` garde tout ce que le relais a vu, pour vérifier ce qu'il ne voit pas.
 */
export function memoryRelay() {
  const rooms = new Map<string, Set<PairSocket & { device: string }>>();
  const log: string[] = [];
  const urls: string[] = [];
  let open = 0;

  const factory: SocketFactory = (url) => {
    urls.push(url);
    const parsed = new URL(url.replace("wss://", "https://"));
    const channel = parsed.pathname.replace("/v1/", "");
    const device = parsed.searchParams.get("device") ?? "";
    const room = rooms.get(channel) ?? new Set();
    rooms.set(channel, room);
    let closed = false;
    const socket: PairSocket & { device: string } = {
      device,
      onOpen: null, onMessage: null, onClose: null,
      send(text) {
        if (closed || text.length > 4096) return;
        log.push(text);
        let message: { t?: string; step?: string; pub?: string; box?: string };
        try { message = JSON.parse(text); } catch { return; }
        if (message.t !== "pair") return;
        const outbound = JSON.stringify({ t: "pair", step: message.step, pub: message.pub, box: message.box, from: device });
        for (const other of room) if (other !== socket) queueMicrotask(() => other.onMessage?.(outbound));
      },
      close() {
        if (closed) return;
        closed = true; open--;
        room.delete(socket);
      },
    };
    room.add(socket);
    open++;
    queueMicrotask(() => { if (!closed) socket.onOpen?.(); });
    return socket;
  };

  return { factory, log, urls, openSockets: () => open, rooms };
}
