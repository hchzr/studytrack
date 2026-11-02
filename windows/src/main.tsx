import "./ui/tokens.css";
import "./ui/kit.css";
import React from "react";
import ReactDOM from "react-dom/client";

// Un seul bundle, deux fenêtres : `?window=mini` est le chrono flottant (créé par
// Rust, voir src-tauri/src/native/mini.rs) ; sinon, l'app. Les imports sont
// différés pour que la petite fenêtre ne charge ni la base ni les écrans.
async function boot() {
  const root = ReactDOM.createRoot(document.getElementById("root") as HTMLElement);
  if (new URLSearchParams(window.location.search).get("window") === "mini") {
    const { MiniTimer } = await import("./ui/mini/MiniTimer.tsx");
    root.render(<React.StrictMode><MiniTimer /></React.StrictMode>);
    return;
  }
  // Les secrets (jetons, session) sortent du coffre du système avant le premier
  // écran : les réglages se lisent ensuite de façon synchrone.
  const { loadSecrets } = await import("./native/secrets.ts");
  await loadSecrets();
  // Avant toute lecture d'un cours : fiche de révision et carte décodées en types du domaine.
  await import("./domain/registerCodecs.ts");
  const { default: App } = await import("./App");
  root.render(<React.StrictMode><App /></React.StrictMode>);
}

void boot();
