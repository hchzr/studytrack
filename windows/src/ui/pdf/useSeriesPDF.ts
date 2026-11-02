import { useEffect, useState } from "react";
import { SeriesPDFStore } from "../../services/seriesPDFStore.ts";

/** Le PDF gardé d'une série, s'il y en a un sur l'appareil (`SeriesPDFStore.localFile`). */
export function useSeriesPDF(seriesID: string | null): Uint8Array | null {
  const [bytes, setBytes] = useState<Uint8Array | null>(null);
  useEffect(() => {
    let alive = true;
    setBytes(null);
    if (seriesID === null) return;
    void SeriesPDFStore.localFile(seriesID).then((value) => { if (alive) setBytes(value); });
    return () => { alive = false; };
  }, [seriesID]);
  return bytes;
}
