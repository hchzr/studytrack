import { describe, expect, it } from "vitest";
import { entryID, isCollection, isMediaSpaceVideo } from "../../src/services/mediaspace.ts";

describe("MediaSpace", () => {
  it("lit l'identifiant d'une vidéo", () => {
    expect(entryID("https://mediaspace.epfl.ch/media/t/0_6y8w1d2s")).toBe("0_6y8w1d2s");
    expect(entryID("https://mediaspace.epfl.ch/media/Lecture+1/0_abcdefgh?x=1")).toBe("0_abcdefgh");
    expect(entryID("https://mediaspace.epfl.ch/channel/foo/123")).toBeNull();
  });
  it("distingue une vidéo d'une liste", () => {
    expect(isCollection("https://mediaspace.epfl.ch/channel/PHYS-101/123")).toBe(true);
    expect(isCollection("https://mediaspace.epfl.ch/playlist/dedicated/1_aaaaaaaa")).toBe(true);
    expect(isCollection("https://mediaspace.epfl.ch/playlist/dedicated/1_aaaaaaaa/0_bbbbbbbb")).toBe(false);
    expect(isMediaSpaceVideo("https://mediaspace.epfl.ch/media/t/0_6y8w1d2s")).toBe(true);
    expect(isMediaSpaceVideo("https://mediaspace.epfl.ch/channel/x/1")).toBe(false);
    expect(isMediaSpaceVideo("https://moodle.epfl.ch/mod/url/view.php?id=0_6y8w1d2s")).toBe(false);
  });
});
