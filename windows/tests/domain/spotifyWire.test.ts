import { describe, expect, it } from "vitest";
import { clusterPayloads, commandBody, clientVersion, latestSecret, nowFromCluster, nowFromWebAPI, playlists, spotifyURI, totp, SpotifyWire, volumeBody, webToken } from "../../src/domain/spotifyWire.ts";

// Les mêmes cas que Validation/main.swift (« Spotify ») : les deux ports parlent le même protocole.
describe("spotifyWire", () => {
  const secret = [...SpotifyWire.fallbackSecret.bytes];
  it("TOTP comme pyotp", async () => {
    expect(await totp(secret, new Date(59_000))).toBe("332823");
    expect(await totp(secret, new Date(1_700_000_000_000))).toBe("371599");
  });
  it("la clé la plus récente", () => {
    expect(latestSecret({ "59": [1, 2], "61": [44, 55], x: [3] })?.version).toBe(61);
  });
  it("version du lecteur et jeton", () => {
    expect(clientVersion(`<script id="appServerConfig" type="text/plain">${btoa('{"clientVersion":"1.2.3.g1"}')}</script>`)).toBe("1.2.3.g1");
    expect(webToken({ accessToken: "abc", clientId: "cid", accessTokenExpirationTimestampMs: 1, isAnonymous: true })).toMatchObject({ accessToken: "abc", anonymous: true });
  });
  it("état du dealer en gzip", async () => {
    const payloads = await clusterPayloads({ uri: "hm://connect-state/v1/cluster", headers: { "Transfer-Encoding": "gzip" }, payloads: ["H4sIAAAAAAAA/6tWSs4pLS5JLVKyUqhWSkwuySxLjU9JLctMTo3PTAEKKqUYKtXWAgDNw9NCJwAAAA=="] });
    expect(nowFromCluster(payloads[0]).activeDevice).toBe("d1");
  });
  it("état Connect", () => {
    const now = nowFromCluster({
      active_device_id: "pc", server_timestamp_ms: "10000",
      devices: { pc: { device_id: "pc", name: "PC", device_type: "COMPUTER", volume: 32768 }, hobs_x: { capabilities: { hidden: true } } },
      player_state: { is_playing: true, timestamp: "8000", position_as_of_timestamp: "30000", duration: "200000",
        options: { shuffling_context: true, repeating_track: true },
        track: { uri: "spotify:track:T1", metadata: { title: "Song", artist_name: "Artist", image_url: "spotify:image:ab12" } },
        next_tracks: [{ uri: "spotify:track:T2", metadata: { title: "Next" } }, { uri: "spotify:delimiter" }] },
    });
    expect(now.track).toMatchObject({ title: "Song", artist: "Artist", artwork: "https://i.scdn.co/image/ab12" });
    expect(now.isPlaying).toBe(true);
    expect(now.position).toBeCloseTo(32);
    expect(now.devices.map((d) => d.id)).toEqual(["pc"]);
    expect(now.devices[0].volume).toBeCloseTo(0.5, 2);
    expect(now.upNext.map((t) => t.uri)).toEqual(["spotify:track:T2"]);
  });
  it("Web API en repli", () => {
    const now = nowFromWebAPI({ is_playing: true, progress_ms: 5000, repeat_state: "track", item: { uri: "spotify:track:A", name: "A", duration_ms: 60000, artists: [{ name: "X" }], album: { name: "Al", images: [{ url: "u" }] } }, device: { id: "d", name: "PC", type: "Computer", volume_percent: 40 } });
    expect(now.track?.artist).toBe("X");
    expect(now.repeatTrack && now.repeatContext).toBe(true);
    expect(now.devices[0].volume).toBeCloseTo(0.4);
  });
  it("commandes", () => {
    const play = commandBody({ kind: "play", uri: "spotify:playlist:P" }).command;
    expect(play.endpoint).toBe("play");
    expect((play.context as { url: string }).url).toBe("context://spotify:playlist:P");
    expect(volumeBody(0.5).volume).toBe(32768);
  });
  it("playlists et liens", () => {
    expect(playlists({ items: [{ uri: "spotify:playlist:P", name: "Focus", images: null }] })[0].name).toBe("Focus");
    expect(spotifyURI("https://open.spotify.com/intl-fr/playlist/abc123?si=x")).toBe("spotify:playlist:abc123");
  });
});
