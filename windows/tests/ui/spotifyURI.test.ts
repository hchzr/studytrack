import { describe, expect, it } from "vitest";
import { spotifyURI } from "../../src/ui/studymode/panes/MusicPane.tsx";

describe("lien Spotify → adresse de l'app", () => {
  it("lit les liens partagés et les URI", () => {
    expect(spotifyURI("https://open.spotify.com/playlist/37i9dQZF1DX8NTLI2TtZa6?si=abc")).toBe("spotify:playlist:37i9dQZF1DX8NTLI2TtZa6");
    expect(spotifyURI("https://open.spotify.com/intl-fr/album/1ATL5GLyefJaxhQzSPVrLX")).toBe("spotify:album:1ATL5GLyefJaxhQzSPVrLX");
    expect(spotifyURI("spotify:playlist:abc123")).toBe("spotify:playlist:abc123");
    expect(spotifyURI("https://example.com/playlist/x")).toBeNull();
  });
});
