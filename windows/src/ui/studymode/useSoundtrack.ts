// La règle des pauses (SessionSoundtrack, pur et testé) appliquée au lecteur du système : à la
// pause du rythme, la musique **qui jouait** s'arrête ; au retour au travail, elle reprend.
// On ne relance jamais une musique qu'on n'a pas arrêtée. Par événements : un changement de phase.

import { useEffect, useRef } from "react";
import { SessionSoundtrack, type SoundtrackPhase } from "../../domain/sessionSoundtrack.ts";
import type { DeskMoment } from "../../domain/deskMoment.ts";
import { SystemMedia, readPauseOnBreak } from "../../native/media.ts";

export function useSoundtrack(phase: SoundtrackPhase, moment: DeskMoment): void {
  const previous = useRef<SoundtrackPhase | null>(null);
  const paused = useRef(false);
  useEffect(() => {
    const from = previous.current;
    previous.current = phase;
    if (from === phase || !readPauseOnBreak()) return;
    const action = SessionSoundtrack.action({ from, to: phase, moment, hasChoice: true, ownsPlayback: true, policy: "pause" });
    if (action === "fadeOutAndPause") {
      void SystemMedia.state().then((state) => {
        if (state.available && state.playing) {
          paused.current = true;
          void SystemMedia.command("pause");
        }
      });
    } else if (action === "resumeAndFadeIn" && paused.current) {
      paused.current = false;
      void SystemMedia.command("play");
    }
  }, [phase, moment]);
}
