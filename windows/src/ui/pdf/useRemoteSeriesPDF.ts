import { useCallback, useEffect, useRef, useState } from "react";
import { SeriesPDFError, SeriesPDFStore, mapError } from "../../services/seriesPDFStore.ts";

export interface RemoteSeriesPDF {
  /** Le PDF, une fois sur l'appareil. */
  bytes: Uint8Array | null;
  /** Une copie locale existe, ou l'adresse de la série mène à un PDF qu'on peut télécharger. */
  available: boolean;
  loading: boolean;
  error: SeriesPDFError | null;
  /** Télécharge (si besoin) maintenant ; sans effet si c'est déjà fait ou en cours. */
  load: () => void;
}

/// Le PDF d'une série : la copie de l'appareil, sinon téléchargé **à la demande**
/// (`load`, ou `auto` à l'ouverture du visualiseur) — jamais en arrière-plan, et
/// une seule tentative par ouverture : un échec attend un clic sur « Réessayer ».
export function useRemoteSeriesPDF(series: { id: string; urlString: string } | null, auto = false): RemoteSeriesPDF {
  const id = series?.id ?? null;
  const address = series?.urlString ?? "";
  const [bytes, setBytes] = useState<Uint8Array | null>(null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<SeriesPDFError | null>(null);
  const [local, setLocal] = useState(false);
  const alive = useRef(true);
  const attempted = useRef<string | null>(null);

  useEffect(() => {
    alive.current = true;
    setBytes(null); setError(null); setLoading(false); setLocal(false);
    attempted.current = null;
    if (id === null) return;
    void SeriesPDFStore.localFile(id).then((value) => {
      if (!alive.current) return;
      setBytes(value);
      setLocal(value !== null);
    });
    return () => { alive.current = false; };
  }, [id]);

  const load = useCallback(() => {
    if (id === null || bytes !== null || loading) return;
    attempted.current = id;
    setLoading(true);
    setError(null);
    SeriesPDFStore.ensure({ id, urlString: address })
      .then((value) => { if (alive.current) setBytes(value); })
      .catch((failure) => { if (alive.current) setError(mapError(failure)); })
      .finally(() => { if (alive.current) setLoading(false); });
  }, [id, address, bytes, loading]);

  useEffect(() => {
    if (auto && id !== null && attempted.current !== id && bytes === null && SeriesPDFStore.hasRemoteDocument(address)) load();
  }, [auto, id, address, bytes, load]);

  return { bytes, available: local || bytes !== null || SeriesPDFStore.hasRemoteDocument(address), loading, error, load };
}
