// Une erreur d'affichage ne doit jamais laisser un écran vide : sans garde, React démonte
// tout et il ne reste que le fond de la page (l'« écran beige »). Pire en mode étude :
// la fenêtre tient l'écran, et la sortie d'urgence disparaissait avec le reste.
// Ici, l'erreur se dit, en clair, et on peut réessayer.

import { Component, type ErrorInfo, type ReactNode } from "react";

interface Props {
  children: ReactNode;
  /** Ce qui s'est cassé, pour le message (« Ce panneau », « StudyTrack »). */
  label?: string;
  /** Quand cette valeur change, on réessaie tout seul (un autre panneau, un autre écran). */
  resetKey?: unknown;
}

interface State { error: Error | null }

export class ErrorBoundary extends Component<Props, State> {
  state: State = { error: null };

  static getDerivedStateFromError(error: Error): State {
    return { error };
  }

  componentDidCatch(error: Error, info: ErrorInfo): void {
    console.error("[StudyTrack] affichage en échec", error, info.componentStack);
  }

  componentDidUpdate(prev: Props): void {
    if (this.state.error && prev.resetKey !== this.props.resetKey) this.setState({ error: null });
  }

  render(): ReactNode {
    const { error } = this.state;
    if (!error) return this.props.children;
    return (
      <div role="alert" style={{
        height: "100%", minHeight: 240, display: "flex", flexDirection: "column", alignItems: "center",
        justifyContent: "center", gap: 12, padding: 24, textAlign: "center", color: "var(--ink)",
      }}>
        <span className="serif" style={{ fontSize: 22 }}>{this.props.label ?? "Cet écran"} n'a pas pu s'afficher</span>
        <code className="mono" style={{
          maxWidth: 640, fontSize: 12, color: "var(--ink-secondary)", whiteSpace: "pre-wrap", wordBreak: "break-word",
        }}>
          {error.name}: {error.message}
        </code>
        <button type="button" className="btn" onClick={() => this.setState({ error: null })}>Réessayer</button>
      </div>
    );
  }
}
