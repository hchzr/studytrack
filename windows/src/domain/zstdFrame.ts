/// Une trame zstd **sans compression** (blocs « bruts », RFC 8878 §3.1.1).
///
/// Le format récent du protocole d'AnkiWeb exige un corps zstd. Il ne sert à
/// l'app que pour découvrir le serveur du compte (`AnkiWebClient.discoverServer`)
/// et une trame valide se compose sans compresser — en-tête de trame, puis des
/// blocs bruts de 128 Kio au plus.
export const ZstdFrame = {
  magic: [0x28, 0xb5, 0x2f, 0xfd] as readonly number[],
  maxBlock: 128 * 1024,

  stored(data: Uint8Array): Uint8Array {
    const out: number[] = [...ZstdFrame.magic];
    // Descripteur : Single_Segment = 1 (pas de fenêtre), taille du contenu
    // sur 4 octets (Frame_Content_Size_flag = 2), pas de somme de contrôle.
    out.push(0b1010_0000);
    const size = data.length >>> 0;
    out.push(size & 0xff, (size >>> 8) & 0xff, (size >>> 16) & 0xff, (size >>> 24) & 0xff);
    let offset = 0;
    do {
      const length = Math.min(ZstdFrame.maxBlock, data.length - offset);
      const isLast = offset + length >= data.length;
      // En-tête de bloc (3 octets) : dernier bloc, type 0 (brut), taille.
      const header = ((length << 3) | (isLast ? 1 : 0)) >>> 0;
      out.push(header & 0xff, (header >>> 8) & 0xff, (header >>> 16) & 0xff);
      for (let i = 0; i < length; i++) out.push(data[offset + i]);
      offset += length;
    } while (offset < data.length);
    return Uint8Array.from(out);
  },
};
