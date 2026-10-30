/** Le temps d'un « maintiens pour finir » : où en est le doigt, et quand le
 * geste compte comme tenu.
 *
 * C'est la seule partie du geste qui puisse se tromper au point qu'on ne
 * termine plus — le défaut signalé : « Maintiens pour finir » ne semblait pas
 * arrêter la session. Le calcul du temps et du relâchement est ici, pur et testé.
 */
export class HoldProgress {
  /** Au-delà de cette distance du point de contact, l'appui se relâche : un
   * doigt qui glisse défile la page au lieu de terminer la session. */
  static readonly slack = 44;

  /** Ce que le doigt doit tenir, en secondes. Zéro : un appui suffit. */
  readonly duration: number;

  constructor(duration: number) {
    this.duration = Math.max(0, duration);
  }

  /** La fraction tenue (0 → 1) au bout de `elapsed` secondes. */
  fraction(elapsed: number): number {
    if (!(this.duration > 0)) return 1;
    return Math.min(Math.max(elapsed / this.duration, 0), 1);
  }

  /** Le geste est-il allé au bout ? */
  isComplete(elapsed: number): boolean {
    return this.fraction(elapsed) >= 1;
  }

  /** Ce qu'il reste à tenir, pour le dire au doigt. */
  remaining(elapsed: number): number {
    return Math.max(0, this.duration - elapsed);
  }

  /** Le contact est-il encore sur le bouton ? */
  static isOnButton(translation: { width: number; height: number }): boolean {
    return Math.hypot(translation.width, translation.height) <= HoldProgress.slack;
  }

  /** L'appui relâché trop tôt mérite-t-il d'être expliqué ? Oui dès que le
   * doigt a commencé à tenir un geste qui demande du temps : un appui bref
   * (taper, pas tenir) ne le mérite pas. */
  shouldExplainRelease(elapsed: number): boolean {
    return this.duration > 0 && !this.isComplete(elapsed) && elapsed >= 0.08;
  }
}
