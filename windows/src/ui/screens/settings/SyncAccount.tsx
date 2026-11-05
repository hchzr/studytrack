// Se connecter ou créer un compte, une chose à la fois : Google d'abord (un clic),
// sinon l'e-mail — deux onglets, puis, à l'inscription, le code reçu par e-mail
// tapé ici même (pas de lien qui ouvre une page web au hasard).

import { useEffect, useState, type FormEvent, type ReactNode } from "react";
import { Button, Segmented } from "../../kit.tsx";
import { syncService } from "../../../services/syncService.ts";

type Mode = "signin" | "signup";
type Stage = { kind: "form" } | { kind: "verify"; email: string; password: string };

const MIN_PASSWORD = 6;
const RESEND_COOLDOWN = 60;

function Field({ label, hint, children }: { label: string; hint?: string; children: ReactNode }) {
  return (
    <label className="settings-form-field">
      <span>{label}</span>
      {children}
      {hint && <small className="account-hint">{hint}</small>}
    </label>
  );
}

/** Le « G » de Google, en couleurs (les consignes de marque le demandent sur le bouton). */
function GoogleMark() {
  return (
    <svg width="16" height="16" viewBox="0 0 48 48" aria-hidden>
      <path fill="#FFC107" d="M43.6 20.5H42V20H24v8h11.3C33.7 32.7 29.2 36 24 36c-6.6 0-12-5.4-12-12s5.4-12 12-12c3.1 0 5.8 1.2 7.9 3.1l5.7-5.7C34 6.1 29.3 4 24 4 12.9 4 4 12.9 4 24s8.9 20 20 20 20-8.9 20-20c0-1.3-.1-2.4-.4-3.5z" />
      <path fill="#FF3D00" d="M6.3 14.7l6.6 4.8C14.7 15.1 19 12 24 12c3.1 0 5.8 1.2 7.9 3.1l5.7-5.7C34 6.1 29.3 4 24 4 16.3 4 9.7 8.3 6.3 14.7z" />
      <path fill="#4CAF50" d="M24 44c5.2 0 9.9-2 13.4-5.2l-6.2-5.2C29.2 35.1 26.7 36 24 36c-5.2 0-9.6-3.3-11.3-8l-6.5 5C9.5 39.6 16.2 44 24 44z" />
      <path fill="#1976D2" d="M43.6 20.5H42V20H24v8h11.3c-.8 2.2-2.2 4.2-4.1 5.6l6.2 5.2C37 39.2 44 34 44 24c0-1.3-.1-2.4-.4-3.5z" />
    </svg>
  );
}

/** La pomme d'Apple, de la couleur du texte du bouton (consignes d'Apple : noir sur blanc ou blanc sur noir). */
function AppleMark() {
  return (
    <svg width="15" height="15" viewBox="0 0 814 1000" aria-hidden fill="currentColor">
      <path d="M788 341c-6 4-108 62-108 190 0 149 131 201 135 202-1 3-21 72-69 142-43 62-88 124-156 124s-86-40-164-40c-77 0-104 41-167 41s-106-57-156-128C45 789 0 668 0 553 0 368 120 270 239 270c63 0 115 41 155 41 38 0 97-44 169-44 27 0 125 2 190 74zM555 168c30-35 51-84 51-133 0-7-1-14-2-19-48 2-106 32-140 72-27 31-53 80-53 130 0 8 1 15 2 18 3 1 8 1 13 1 43 0 98-29 129-69z" />
    </svg>
  );
}

export function SyncAccount() {
  const [mode, setMode] = useState<Mode>("signin");
  const [stage, setStage] = useState<Stage>({ kind: "form" });
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [confirm, setConfirm] = useState("");
  const [code, setCode] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [busy, setBusy] = useState<"google" | "apple" | "submit" | "verify" | "resend" | "link" | null>(null);
  const [cooldown, setCooldown] = useState(0);

  // Le décompte du « Renvoyer » : un réveil par seconde, seulement pendant qu'il court.
  useEffect(() => {
    if (cooldown <= 0) return;
    const id = setTimeout(() => setCooldown((c) => c - 1), 1000);
    return () => clearTimeout(id);
  }, [cooldown]);

  const run = async (kind: NonNullable<typeof busy>, action: () => Promise<void>) => {
    if (busy !== null) return;
    setBusy(kind);
    setError(null);
    setNotice(null);
    try {
      await action();
    } catch (e) {
      setError(e instanceof Error ? e.message : "Ça n'a pas marché, réessaie.");
    } finally {
      setBusy(null);
    }
  };

  const switchMode = (next: Mode) => {
    setMode(next);
    setError(null);
    setNotice(null);
    setConfirm("");
  };

  const trimmed = email.trim();
  const signupProblem = mode === "signup"
    ? password.length > 0 && password.length < MIN_PASSWORD
      ? `${MIN_PASSWORD} caractères au moins.`
      : confirm.length > 0 && confirm !== password ? "Les deux mots de passe ne sont pas les mêmes." : null
    : null;
  const canSubmit = trimmed !== "" && password !== ""
    && (mode === "signin" || (password.length >= MIN_PASSWORD && confirm === password));

  const submit = (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    if (!canSubmit) return;
    void run("submit", async () => {
      if (mode === "signin") {
        await syncService.signIn(trimmed, password);
        return;
      }
      const outcome = await syncService.signUp(trimmed, password);
      if (outcome === "confirm") {
        setStage({ kind: "verify", email: trimmed, password });
        setCode("");
        setCooldown(RESEND_COOLDOWN);
      }
    });
  };

  if (stage.kind === "verify") {
    const digits = code.replace(/\D/g, "");
    return (
      <form className="account" onSubmit={(event) => {
        event.preventDefault();
        if (digits.length < 6) return;
        void run("verify", () => syncService.verifySignUp(stage.email, digits));
      }}>
        <div className="account-head">
          <h3 className="serif">Vérifie ta boîte mail</h3>
          <p className="settings-hint">
            Un code de confirmation est parti à <strong>{stage.email}</strong>. Tape-le ici.
            Rien reçu ? Regarde dans les indésirables, ou renvoie-le.
          </p>
        </div>

        <Field label="Code reçu par e-mail">
          <input className="field account-code mono" inputMode="numeric" autoComplete="one-time-code"
            autoFocus maxLength={12} placeholder="123456" value={code} aria-label="Code reçu par e-mail"
            onChange={(event) => setCode(event.target.value)} />
        </Field>

        {error && <p className="settings-error" role="alert">{error}</p>}
        {notice && <p className="settings-hint" role="status">{notice}</p>}

        <Button type="submit" variant="primary" className="account-main" disabled={busy !== null || digits.length < 6}>
          {busy === "verify" ? "Vérification…" : "Confirmer mon adresse"}
        </Button>

        <div className="account-links">
          <button type="button" className="link-btn" disabled={busy !== null || cooldown > 0}
            onClick={() => void run("resend", async () => {
              await syncService.resendSignUp(stage.email);
              setNotice("Nouveau message envoyé.");
              setCooldown(RESEND_COOLDOWN);
            })}>
            {cooldown > 0 ? `Renvoyer le code (${cooldown} s)` : busy === "resend" ? "Envoi…" : "Renvoyer le code"}
          </button>
          <span aria-hidden>·</span>
          <button type="button" className="link-btn" disabled={busy !== null}
            title="Si tu as cliqué le lien du message plutôt que de taper le code"
            onClick={() => void run("link", () => syncService.signIn(stage.email, stage.password))}>
            J'ai cliqué le lien du message
          </button>
          <span aria-hidden>·</span>
          <button type="button" className="link-btn" disabled={busy !== null}
            onClick={() => { setStage({ kind: "form" }); setError(null); setNotice(null); }}>
            Changer d'adresse
          </button>
        </div>
      </form>
    );
  }

  return (
    <div className="account">
      <div className="account-head">
        <h3 className="serif">Ton compte Polymestre</h3>
        <p className="settings-hint">
          Pour retrouver tes cours, séries et sessions sur ton iPhone, ton Mac ou un autre PC.
          Tout est chiffré sur tes appareils : le serveur ne peut rien lire.
        </p>
      </div>

      <Button className="account-main account-apple" disabled={busy !== null}
        onClick={() => void run("apple", () => syncService.signInWithApple())}>
        <AppleMark />
        {busy === "apple" ? "Termine dans ton navigateur…" : "Continuer avec Apple"}
      </Button>
      <Button className="account-main" disabled={busy !== null}
        onClick={() => void run("google", () => syncService.signInWithGoogle())}>
        <GoogleMark />
        {busy === "google" ? "Termine dans ton navigateur…" : "Continuer avec Google"}
      </Button>
      {(busy === "google" || busy === "apple") && (
        <p className="settings-hint">
          Une page s'est ouverte dans ton navigateur : connecte-toi, puis reviens ici.{" "}
          <button type="button" className="link-btn" onClick={() => syncService.cancelOAuth()}>Annuler</button>
        </p>
      )}
      <p className="settings-hint account-center">
        Tu as créé ton compte sur iPhone avec Apple ? Choisis « Continuer avec Apple » : c'est le même compte.
      </p>

      <div className="account-or"><span>ou avec ton e-mail</span></div>

      <Segmented
        ariaLabel="Se connecter ou créer un compte"
        value={mode}
        onChange={switchMode}
        options={[{ value: "signin", label: "J'ai déjà un compte" }, { value: "signup", label: "Créer un compte" }]}
      />

      <form className="account-fields" onSubmit={submit}>
        <Field label="Adresse e-mail">
          <input className="field" type="email" required value={email} autoComplete="email"
            placeholder="prenom.nom@exemple.ch" aria-label="Adresse e-mail"
            onChange={(event) => setEmail(event.target.value)} />
        </Field>
        <Field label="Mot de passe" hint={mode === "signup" ? `${MIN_PASSWORD} caractères au moins.` : undefined}>
          <input className="field" type="password" required value={password}
            autoComplete={mode === "signin" ? "current-password" : "new-password"} aria-label="Mot de passe"
            onChange={(event) => setPassword(event.target.value)} />
        </Field>
        {mode === "signup" && (
          <Field label="Le même mot de passe, encore une fois">
            <input className="field" type="password" required value={confirm} autoComplete="new-password"
              aria-label="Confirmer le mot de passe" onChange={(event) => setConfirm(event.target.value)} />
          </Field>
        )}

        {(error ?? signupProblem) && <p className="settings-error" role="alert">{error ?? signupProblem}</p>}

        <Button type="submit" variant="primary" className="account-main" disabled={busy !== null || !canSubmit}>
          {busy === "submit"
            ? mode === "signin" ? "Connexion…" : "Création…"
            : mode === "signin" ? "Se connecter" : "Créer mon compte"}
        </Button>
        {mode === "signup" && (
          <p className="settings-hint account-center">Un code de confirmation va partir à cette adresse.</p>
        )}
      </form>
    </div>
  );
}
