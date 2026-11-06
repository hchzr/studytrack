// L'appairage par le relais : le cas heureux, un mauvais code, une seule tentative par code,
// l'expiration, et ce que voit le relais.
import { describe, expect, it, vi } from "vitest";
import { PairingHost, joinPairing, pairingURL, type HostState, type SocketFactory } from "../../src/services/syncPairing.ts";
import { deriveKeys, encodePairingCode, newAccountKey, newPairingSecret, toHex } from "../../src/domain/syncCrypto.ts";
import { memoryRelay } from "../helpers/memoryRelay.ts";

async function setup() {
  const ak = newAccountKey();
  const { keyId } = await deriveKeys(ak);
  const relay = memoryRelay();
  const states: HostState[] = [];
  return { ak, keyId, relay, states };
}

describe("appairage", () => {
  it("cas heureux : B reçoit exactement la clé de A, les deux disent « terminé »", async () => {
    const { ak, keyId, relay, states } = await setup();
    const host = await PairingHost.start({ accountKey: ak, host: "relay.test", makeSocket: relay.factory, onState: (s) => states.push(s) });
    const got = await joinPairing({ code: host.code, expectedKeyId: keyId, host: "relay.test", makeSocket: relay.factory });
    expect(toHex(got)).toBe(toHex(ak));
    await vi.waitFor(() => expect(host.state).toBe("done"));
    expect(states).toEqual(["verifying", "done"]);
    expect(relay.openSockets()).toBe(0);
    // Le relais n'a vu passer ni la clé, ni le code, ni son hex.
    const seen = relay.log.join("") + relay.urls.join("");
    expect(seen).not.toContain(toHex(ak));
    expect(seen).not.toContain(host.code);
    // L'URL de l'appairage est celle que le relais attend.
    expect(relay.urls[0]).toMatch(/^wss:\/\/relay\.test\/v1\/pair-[0-9a-f]{32}\?device=[0-9a-f-]{36}$/);
  });

  it("le QR (« polymestre-pair:… ») et la saisie approximative marchent", async () => {
    const { ak, keyId, relay } = await setup();
    const host = await PairingHost.start({ accountKey: ak, host: "r", makeSocket: relay.factory });
    const typed = "polymestre-pair:" + host.code.toLowerCase().replace(/-/g, " ");
    expect(toHex(await joinPairing({ code: typed, expectedKeyId: keyId, host: "r", makeSocket: relay.factory }))).toBe(toHex(ak));
  });

  it("mauvais code : personne ne répond, message calme", async () => {
    const { ak, keyId, relay } = await setup();
    const host = await PairingHost.start({ accountKey: ak, host: "r", makeSocket: relay.factory });
    const wrong = encodePairingCode(newPairingSecret());
    await expect(joinPairing({ code: wrong, expectedKeyId: keyId, host: "r", makeSocket: relay.factory, timeoutMs: 50 }))
      .rejects.toMatchObject({ kind: "timeout" });
    expect(host.state).toBe("waiting");
    host.cancel();
  });

  it("code mal formé : refusé tout de suite, sans toucher au réseau", async () => {
    const { keyId, relay } = await setup();
    await expect(joinPairing({ code: "1234", expectedKeyId: keyId, host: "r", makeSocket: relay.factory })).rejects.toMatchObject({ kind: "code" });
    expect(relay.urls).toEqual([]);
  });

  it("même salon, mauvais secret : le déchiffrement échoue, rien n'est rangé", async () => {
    const { ak, keyId, relay } = await setup();
    const host = await PairingHost.start({ accountKey: ak, host: "r", makeSocket: relay.factory });
    // B se trompe de code mais, par malchance (ou un attaquant), tombe sur le salon de A.
    const wrong = newPairingSecret();
    const aChannel = relay.urls[0].match(/pair-[0-9a-f]{32}/)![0];
    const redirect: SocketFactory = (url) => relay.factory(url.replace(/pair-[0-9a-f]{32}/, aChannel));
    await expect(joinPairing({ code: encodePairingCode(wrong), expectedKeyId: keyId, host: "r", makeSocket: redirect }))
      .rejects.toMatchObject({ kind: "wrongCode" });
    expect(host.state).toBe("verifying"); // A a répondu une fois, et attend une confirmation qui ne viendra pas
    // Une tentative par code : un deuxième appareil ne reçoit plus rien.
    await expect(joinPairing({ code: host.code, expectedKeyId: keyId, host: "r", makeSocket: relay.factory, timeoutMs: 80 }))
      .rejects.toMatchObject({ kind: "timeout" });
    host.cancel();
  });

  it("la clé reçue doit être celle du coffre du compte connecté", async () => {
    const { ak, relay } = await setup();
    const host = await PairingHost.start({ accountKey: ak, host: "r", makeSocket: relay.factory });
    await expect(joinPairing({ code: host.code, expectedKeyId: "0".repeat(32), host: "r", makeSocket: relay.factory }))
      .rejects.toMatchObject({ kind: "otherAccount" });
    host.cancel();
  });

  it("le code expire au bout de dix minutes ; annuler ferme la socket", async () => {
    const { ak, relay } = await setup();
    let fire: (() => void) | null = null;
    const states: HostState[] = [];
    const host = await PairingHost.start({
      accountKey: ak, host: "r", makeSocket: relay.factory, onState: (s) => states.push(s),
      setTimer: (fn, ms) => { expect(ms).toBe(600_000); fire = fn; return () => { fire = null; }; },
    });
    expect(relay.openSockets()).toBe(1);
    fire!();
    expect(host.state).toBe("expired");
    expect(relay.openSockets()).toBe(0);
    expect(states).toEqual(["expired"]);

    const second = await PairingHost.start({ accountKey: ak, host: "r", makeSocket: relay.factory });
    second.cancel();
    expect(second.state).toBe("cancelled");
    expect(relay.openSockets()).toBe(0);
  });

  it("l'URL du salon", () => {
    expect(pairingURL("h.dev", "pair-ab", "d")).toBe("wss://h.dev/v1/pair-ab?device=d");
  });
});
