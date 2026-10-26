/** Ce que le bandeau au-dessus de la saisie montre : un blocage, une alerte, l'observation. */
export type Band = { tone: 'block' | 'warn' | 'observe'; text: string }

declare module 'claude-code' {
  interface PluginState {
    mesure: { band: Band | null }
  }
}
