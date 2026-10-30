/**
 * **Inutilisé** : gardé pour la symétrie avec le schéma Swift. Le chrono passe par le
 * relais et le magasin clé-valeur (`CloudRelay`), pas par la base.
 */
export class RelayBeacon {
  static readonly modelName = "RelayBeacon";

  device: string;
  updatedAt: Date;
  /** `CloudRelay.TimerSnapshot`, encodé. */
  payload: Uint8Array | null;

  constructor(o: { device: string; updatedAt?: Date; payload?: Uint8Array | null }) {
    this.device = o.device;
    this.updatedAt = o.updatedAt ?? new Date();
    this.payload = o.payload ?? null;
  }
}
