// Mode étude — le bureau immersif plein écran (StudyTrackMac/StudyMode/*).
// Première version : panneaux qui marchent sur les données (exercice, notes,
// chrono, fiche de révision, vue calme). À faire par le job dsh.
// Reportés (dépendent du natif Tauri) : panneau Claude (lance Claude Code),
// navigateur intégré, blocage système des applications.

export function StudyModeView({ onExit }: { onExit: () => void }) {
  return (
    <div style={{ position: "fixed", inset: 0, background: "var(--ground)", zIndex: 100,
      display: "flex", alignItems: "center", justifyContent: "center", flexDirection: "column", gap: 16 }}>
      <div className="serif" style={{ fontSize: 28 }}>Mode étude</div>
      <p style={{ color: "var(--ink-secondary)" }}>Bureau immersif — à porter depuis StudyTrackMac/StudyMode/.</p>
      <button onClick={onExit} className="card" style={{ padding: "8px 20px" }}>Quitter</button>
    </div>
  );
}
