// Les transcriptions des vidéos Courseware : ce que dit chaque vidéo, phrase par
// phrase, avec son instant (StudyTrack/Domain/CoursewareTranscripts.swift).

export interface Cue {
  start: number;
  text: string;
}

export interface CoursewareVideo {
  block: string;
  unit: string;
  title: string;
  cues: Cue[];
}

export interface TranscriptHit {
  block: string;
  unit: string;
  title: string;
  start: number;
  /** La phrase trouvée, avec un peu de ce qui l'entoure. */
  snippet: string;
  id: string;
}

export const CoursewareTranscripts = {
  /** `CoursewareTranscripts.Video(block:unit:title:cues:)` / `Cue(start:text:)`. */
  Video(block: string, unit: string, title: string, cues: Cue[]): CoursewareVideo { return { block, unit, title, cues }; },
  Cue(start: number, text: string): Cue { return { start, text }; },

  // MARK: Lire

  /** SRT (`1\n00:01:02,500 --> …\ntexte`) ou le JSON d'edX. */
  cues(from: string): Cue[] {
    const trimmed = from.trim();
    if (trimmed.startsWith("{")) {
      let object: Record<string, any> | null = null;
      try {
        const parsed = JSON.parse(trimmed);
        if (parsed !== null && typeof parsed === "object" && !Array.isArray(parsed)) object = parsed;
      } catch {
        object = null;
      }
      if (object !== null && Array.isArray(object["start"]) && Array.isArray(object["text"])) {
        const starts = object["start"].filter((x: unknown): x is number => typeof x === "number");
        const texts = object["text"].filter((x: unknown): x is string => typeof x === "string");
        const result: Cue[] = [];
        const count = Math.min(starts.length, texts.length);
        for (let i = 0; i < count; i += 1) {
          const clean = CoursewareTranscripts.tidy(texts[i]);
          if (clean !== "") result.push({ start: starts[i] / 1000, text: clean });
        }
        return result;
      }
    }
    const result: Cue[] = [];
    const blocks = trimmed.split("\r\n").join("\n").split("\n\n");
    for (const block of blocks) {
      const lines = block.split("\n").filter((line) => line !== "");
      const timing = lines.findIndex((line) => line.includes("-->"));
      if (timing < 0) continue;
      const start = CoursewareTranscripts.seconds(lines[timing].split("-->")[0]);
      if (start === null) continue;
      const text = CoursewareTranscripts.tidy(lines.slice(timing + 1).join(" "));
      if (text !== "") result.push({ start, text });
    }
    return result;
  },

  /** `00:01:02,500` → 62.5. */
  seconds(stamp: string): number | null {
    const parts = stamp.trim().split(",").join(".").split(":");
    if (parts.length < 2 || parts.length > 3) return null;
    let total = 0;
    for (const part of parts) {
      const value = Number(part);
      if (!Number.isFinite(value)) return null;
      total = total * 60 + value;
    }
    return total;
  },

  tidy(text: string): string {
    return text.replace(/<[^>]+>/g, "").replace(/\s+/g, " ").trim();
  },

  /** Les adresses des transcriptions d'un bloc vidéo, la langue préférée d'abord (fr, puis en). */
  transcriptURLs(data: Record<string, any>, preferred: string[] = ["fr", "en"]): string[] {
    const raw = data["transcripts"];
    const transcripts: Record<string, string> = raw !== null && typeof raw === "object" && !Array.isArray(raw)
      ? raw as Record<string, string> : {};
    const ordered: string[] = [];
    for (const language of preferred) {
      const value = transcripts[language];
      if (typeof value === "string") ordered.push(value);
    }
    for (const key of Object.keys(transcripts).filter((k) => !preferred.includes(k)).sort()) {
      ordered.push(transcripts[key]);
    }
    return ordered.filter((value) => value !== "");
  },

  // MARK: Chercher

  /** Les passages qui contiennent tous les mots cherchés, lus sur trois phrases de suite. */
  search(query: string, videos: CoursewareVideo[], limit = 40): TranscriptHit[] {
    const words = CoursewareTranscripts.fold(query).split(" ").filter((word) => [...word].length >= 2);
    if (words.length === 0) return [];
    const hits: TranscriptHit[] = [];
    for (const video of videos) {
      let lastMinute = -1;
      for (let index = 0; index < video.cues.length; index += 1) {
        const window = video.cues.slice(index, Math.min(index + 3, video.cues.length));
        const text = window.map((cue) => cue.text).join(" ");
        const folded = CoursewareTranscripts.fold(text);
        if (!words.every((word) => folded.includes(word))) continue;
        // La phrase qui porte le premier mot, plutôt que le début de la fenêtre.
        const anchor = window.find((cue) => CoursewareTranscripts.fold(cue.text).includes(words[0])) ?? video.cues[index];
        const minute = Math.trunc(anchor.start / 60);
        if (minute === lastMinute) continue;
        lastMinute = minute;
        hits.push({
          block: video.block, unit: video.unit, title: video.title, start: anchor.start,
          snippet: [...text].slice(0, 220).join(""), id: video.block + "@" + String(Math.trunc(anchor.start)),
        });
        if (hits.length >= limit) return hits;
      }
    }
    return hits;
  },

  fold(text: string): string {
    return text.normalize("NFD").replace(/\p{M}+/gu, "").toLowerCase();
  },
};
