import { beforeEach, describe, expect, it, vi } from "vitest";

const written: { path: string; bytes: Uint8Array }[] = [];
vi.mock("../../src/native/tauri.ts", () => ({ inNative: () => true, callNativeOrThrow: vi.fn() }));
vi.mock("@tauri-apps/plugin-fs", () => ({
  BaseDirectory: { AppLocalData: 1 },
  exists: async () => false,
  mkdir: async () => {},
  readFile: async () => new Uint8Array(),
  remove: async () => {},
  writeFile: async (path: string, bytes: Uint8Array) => { written.push({ path, bytes }); },
}));

import {
  SeriesPDFError, directURL, documentURL, download, ensure, isPDF, mapError, maxPDFBytes, type DownloadDeps,
} from "../../src/services/seriesPDFStore.ts";
import { SiteError } from "../../src/services/siteSession.ts";

const PDF = new TextEncoder().encode("%PDF-1.7\n...");
const HTML = (body: string) => new TextEncoder().encode(`<html><body>${body}</body></html>`);

function deps(over: Partial<DownloadDeps> = {}): DownloadDeps {
  return { siteBytes: async () => PDF, publicBytes: async () => PDF, ...over };
}

describe("quelle adresse donne un PDF", () => {
  it("un fichier Moodle, une activité Moodle, un lien Dropbox", () => {
    expect(documentURL("https://moodle.epfl.ch/pluginfile.php/1/mod_resource/content/1/s1.pdf")).not.toBeNull();
    expect(documentURL("https://moodle.epfl.ch/mod/resource/view.php?id=42")).not.toBeNull();
    expect(documentURL("https://www.dropbox.com/s/abc/serie.pdf?dl=0")).not.toBeNull();
    expect(documentURL("https://exemple.ch/cours/serie1.pdf")).not.toBeNull();
  });
  it("une page web de série, une adresse vide ou non http n'en est pas une", () => {
    expect(documentURL("https://botafogo.example/cours/serie1")).toBeNull();
    expect(documentURL("")).toBeNull();
    expect(documentURL("ftp://exemple.ch/s.pdf")).toBeNull();
  });
  it("Dropbox : dl=1 remplace dl=0", () => {
    expect(directURL(new URL("https://www.dropbox.com/s/abc/s.pdf?dl=0")).toString()).toBe("https://www.dropbox.com/s/abc/s.pdf?dl=1");
    expect(directURL(new URL("https://www.dropbox.com/s/abc/s.pdf")).searchParams.get("dl")).toBe("1");
    expect(directURL(new URL("https://exemple.ch/s.pdf?dl=0")).toString()).toBe("https://exemple.ch/s.pdf?dl=0");
  });
});

describe("vérification du PDF", () => {
  it("%PDF en tête", () => {
    expect(isPDF(PDF)).toBe(true);
    expect(isPDF(HTML("connexion"))).toBe(false);
    expect(isPDF(new Uint8Array())).toBe(false);
  });
  it("une page HTML publique est refusée", async () => {
    await expect(download(new URL("https://exemple.ch/s.pdf"), deps({ publicBytes: async () => HTML("x") })))
      .rejects.toMatchObject({ kind: "notPDF" });
  });
  it("plus de 50 Mo est refusé", async () => {
    const big = new Uint8Array(maxPDFBytes + 1); big.set(PDF);
    await expect(download(new URL("https://exemple.ch/s.pdf"), deps({ publicBytes: async () => big })))
      .rejects.toMatchObject({ kind: "tooLarge" });
  });
  it("http (non chiffré) est refusé hors Moodle", async () => {
    await expect(download(new URL("http://exemple.ch/s.pdf"), deps())).rejects.toMatchObject({ kind: "noDocument" });
  });
});

describe("Moodle avec la session", () => {
  it("un PDF direct", async () => {
    const seen: string[] = [];
    const bytes = await download(new URL("https://moodle.epfl.ch/mod/resource/view.php?id=7"), deps({ siteBytes: async (u) => { seen.push(u); return PDF; } }));
    expect(bytes).toBe(PDF);
    expect(seen).toEqual(["https://moodle.epfl.ch/mod/resource/view.php?id=7&redirect=1"]);
  });
  it("une page d'activité est suivie jusqu'au PDF qu'elle désigne", async () => {
    const seen: string[] = [];
    const page = HTML('<a href="/pluginfile.php/9/mod_page/content/enonce.pdf">Énoncé</a>');
    const bytes = await download(new URL("https://moodle.epfl.ch/mod/page/view.php?id=7"), deps({
      siteBytes: async (u) => { seen.push(u); return u.includes("pluginfile") ? PDF : page; },
    }));
    expect(bytes).toBe(PDF);
    expect(seen).toEqual(["https://moodle.epfl.ch/mod/page/view.php?id=7", "https://moodle.epfl.ch/pluginfile.php/9/mod_page/content/enonce.pdf"]);
  });
  it("une page de connexion : pas connecté·e", async () => {
    await expect(download(new URL("https://moodle.epfl.ch/pluginfile.php/1/a/b/s.pdf"), deps({
      siteBytes: async () => HTML('<form action="https://moodle.epfl.ch/login/index.php"></form>'),
    }))).rejects.toMatchObject({ kind: "notSignedIn" });
  });
  it("une page sans lien : pas un PDF", async () => {
    await expect(download(new URL("https://moodle.epfl.ch/pluginfile.php/1/a/b/s.pdf"), deps({ siteBytes: async () => HTML("rien") })))
      .rejects.toMatchObject({ kind: "notPDF" });
  });
  it("site non autorisé de Rust → notSignedIn", async () => {
    await expect(download(new URL("https://moodle.epfl.ch/pluginfile.php/1/a/b/s.pdf"), deps({
      siteBytes: async () => { throw new SiteError("notSignedIn"); },
    }))).rejects.toMatchObject({ kind: "notSignedIn" });
  });
});

describe("messages d'erreur", () => {
  it("chaque cause a sa phrase française", () => {
    expect(mapError(new SiteError("timeout")).message).toBe("Le site ne répond pas. Vérifie ta connexion.");
    expect(mapError(new SiteError("failed", "HTTP 404"))).toMatchObject({ kind: "http", status: 404 });
    expect(mapError(new SiteError("failed", "HTTP 403")).kind).toBe("notSignedIn");
    expect(mapError(new Error("connection refused")).kind).toBe("network");
    expect(new SeriesPDFError("http", 500).message).toBe("Le site a refusé le téléchargement (erreur 500).");
    expect(new SeriesPDFError("notSignedIn").message).toBe("Connecte-toi à Moodle pour télécharger cet énoncé.");
    expect(new SeriesPDFError("notPDF").message).toBe("Ce lien ne mène pas à un PDF.");
  });
});

describe("ensure : téléchargé une fois, gardé sur l'appareil", () => {
  beforeEach(() => { written.length = 0; });
  it("écrit SeriesPDF/<ID>.pdf dans AppLocalData, une seule requête pour deux demandes", async () => {
    let calls = 0;
    const d = deps({ publicBytes: async () => { calls++; return PDF; } });
    const series = { id: "abcd-1234", urlString: "https://exemple.ch/serie.pdf" };
    const [a, b] = await Promise.all([ensure(series, d), ensure(series, d)]);
    expect(a).toBe(PDF); expect(b).toBe(PDF);
    expect(calls).toBe(1);
    expect(written.map((w) => w.path)).toEqual(["SeriesPDF/ABCD-1234.pdf"]);
    expect(written[0].bytes).toBe(PDF);
    // La copie est maintenant locale : plus de téléchargement.
    expect(await ensure(series, d)).toBe(PDF);
    expect(calls).toBe(1);
  });
  it("rien n'est écrit si le téléchargement échoue", async () => {
    await expect(ensure({ id: "ffff-0000", urlString: "https://exemple.ch/s.pdf" }, deps({ publicBytes: async () => HTML("non") })))
      .rejects.toMatchObject({ kind: "notPDF" });
    expect(written).toEqual([]);
  });
  it("une série sans adresse de PDF : noDocument", async () => {
    await expect(ensure({ id: "eeee-0000", urlString: "" }, deps())).rejects.toMatchObject({ kind: "noDocument" });
  });
});
