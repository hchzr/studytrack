// Une vidéo lue dans l'app : MP4 directement, HLS (`.m3u8` des cours et de MediaSpace) par
// hls.js — Chromium (WebView2) ne lit pas le HLS seul. Rien ne part dans un navigateur.

import { useEffect, useRef } from "react";

export function VideoPlayer({ src, poster, onEnded, startAt }: { src: string; poster?: string; onEnded?: () => void; startAt?: number }) {
  const ref = useRef<HTMLVideoElement | null>(null);
  useEffect(() => {
    const video = ref.current;
    if (!video) return;
    let destroy: (() => void) | null = null;
    const seek = () => { if (startAt && startAt > 0) video.currentTime = startAt; };
    if (/\.m3u8($|[?#/])/i.test(src) && !video.canPlayType("application/vnd.apple.mpegurl")) {
      let cancelled = false;
      void import("hls.js").then(({ default: Hls }) => {
        if (cancelled || !Hls.isSupported()) { video.src = src; return; }
        const hls = new Hls({ maxBufferLength: 30 });
        hls.loadSource(src);
        hls.attachMedia(video);
        hls.on(Hls.Events.MANIFEST_PARSED, seek);
        destroy = () => hls.destroy();
      });
      return () => { cancelled = true; destroy?.(); };
    }
    video.src = src;
    video.addEventListener("loadedmetadata", seek, { once: true });
    return () => { video.removeAttribute("src"); video.load(); };
  }, [src, startAt]);
  return (
    <video ref={ref} poster={poster} controls preload="metadata" onEnded={onEnded}
      style={{ width: "100%", maxHeight: "70vh", borderRadius: 10, background: "#000" }} />
  );
}
