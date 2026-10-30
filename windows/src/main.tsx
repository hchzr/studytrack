import "./ui/tokens.css";
import React from "react";
import ReactDOM from "react-dom/client";
import App from "./App";
// Avant toute lecture d'un cours : fiche de révision et carte décodées en types du domaine.
import "./domain/registerCodecs.ts";

ReactDOM.createRoot(document.getElementById("root") as HTMLElement).render(
  <React.StrictMode>
    <App />
  </React.StrictMode>,
);
