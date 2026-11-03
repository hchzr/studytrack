// Les groupes d'étude (GroupsView + GroupHubView de l'iPhone, réduits à l'essentiel) : mes
// groupes, en créer un ou en rejoindre un par son code ; dans un groupe, qui travaille en ce
// moment, le classement de la semaine, les membres et le code à partager.

import { useCallback, useEffect, useState } from "react";
import { Course, StudySession } from "../../models/index.ts";
import { useData } from "../../data/dataContext.tsx";
import { countsSession, readCounting } from "../../domain/studyCounting.ts";
import { DateUtils } from "../../domain/dateUtils.ts";
import { Groups, type Group, type LeaderboardRow, type Member, type Presence } from "../../services/groupsService.ts";
import { readGroupsDisplayName, refreshMyGroups, writeGroupsDisplayName } from "../groups/groupPresence.ts";
import { Button, Card, EmptyState, PageHeader, Section } from "../kit.tsx";
import { Icon } from "../icons.tsx";

const hours = (seconds: number) => {
  const h = Math.floor(seconds / 3600);
  const m = Math.round((seconds % 3600) / 60);
  return h > 0 ? `${h} h ${String(m).padStart(2, "0")}` : `${m} min`;
};

export function GroupsScreen() {
  const [groups, setGroups] = useState<Group[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [open, setOpen] = useState<Group | null>(null);
  const [form, setForm] = useState<"create" | "join" | null>(null);
  const load = useCallback(async () => {
    setError(null);
    try { setGroups(await refreshMyGroups()); } catch (e) { setError(e instanceof Error ? e.message : String(e)); setGroups([]); }
  }, []);
  useEffect(() => { void load(); }, [load]);

  if (open) return <GroupPage group={open} back={() => { setOpen(null); void load(); }} />;
  return (
    <div className="page">
      <PageHeader title="Groupes" subtitle="Travailler à plusieurs : qui bosse en ce moment, le temps de la semaine."
        actions={<>
          <Button icon="plus" onClick={() => setForm("create")}>Créer</Button>
          <Button variant="primary" icon="person.2" onClick={() => setForm("join")}>Rejoindre</Button>
        </>} />
      {error && <p className="settings-error">{error}</p>}
      {form && <GroupForm mode={form} done={(group) => { setForm(null); if (group) setOpen(group); void load(); }} />}
      {groups === null ? <p className="faint">Chargement…</p> : groups.length === 0 && !error ? (
        <Card><EmptyState icon="person.2" title="Pas encore de groupe">Crée-en un et partage son code, ou rejoins celui d'un·e camarade.</EmptyState></Card>
      ) : (
        <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fill, minmax(260px, 1fr))", gap: 12 }}>
          {groups.map((group) => (
            <Card key={group.id} onClick={() => setOpen(group)}>
              <div className="serif" style={{ fontSize: 18 }}>{group.name}</div>
              <div className="faint" style={{ fontSize: 12 }}>{group.courses.join(" · ") || "Toutes matières"}</div>
              <div className="mono faint" style={{ fontSize: 11, marginTop: 6 }}>{group.inviteCode}{group.role === "admin" ? " · admin" : ""}</div>
            </Card>
          ))}
        </div>
      )}
    </div>
  );
}

function GroupForm({ mode, done }: { mode: "create" | "join"; done: (group: Group | null) => void }) {
  const { store } = useData();
  const tracked = store ? store.fetch(Course).filter((c) => c.isTracked).map((c) => c.displayCode) : [];
  const [name, setName] = useState("");
  const [code, setCode] = useState("");
  const [subjects, setSubjects] = useState<string[]>([]);
  const [displayName, setDisplayName] = useState(readGroupsDisplayName);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const submit = async () => {
    setBusy(true);
    setError(null);
    try {
      writeGroupsDisplayName(displayName);
      done(mode === "create" ? await Groups.create(name, subjects, displayName) : await Groups.join(code, displayName));
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
    }
  };
  const ready = displayName.trim() !== "" && (mode === "create" ? name.trim() !== "" : code.trim() !== "");
  return (
    <Card style={{ marginBottom: 16 }}>
      <div style={{ display: "flex", flexDirection: "column", gap: 10, maxWidth: 520 }}>
        <span className="serif" style={{ fontSize: 18 }}>{mode === "create" ? "Nouveau groupe" : "Rejoindre un groupe"}</span>
        {mode === "create"
          ? <input className="field" placeholder="Nom du groupe (« Révisions Analyse »)" value={name} onChange={(e) => setName(e.target.value)} />
          : <input className="field mono" placeholder="Code reçu (EPFL-7K2Q)" value={code} onChange={(e) => setCode(e.target.value)} />}
        <input className="field" placeholder="Ton prénom, tel que le groupe le verra" value={displayName} onChange={(e) => setDisplayName(e.target.value)} />
        {mode === "create" && tracked.length > 0 && (
          <div style={{ display: "flex", flexWrap: "wrap", gap: 6 }}>
            {tracked.map((c) => (
              <button key={c} type="button" className="chip" aria-pressed={subjects.includes(c)}
                onClick={() => setSubjects(subjects.includes(c) ? subjects.filter((s) => s !== c) : [...subjects, c])}>{c}</button>
            ))}
          </div>
        )}
        {error && <span className="settings-error">{error}</span>}
        <div style={{ display: "flex", gap: 8, justifyContent: "flex-end" }}>
          <Button onClick={() => done(null)}>Annuler</Button>
          <Button variant="primary" disabled={busy || !ready} onClick={() => { void submit(); }}>{busy ? "…" : mode === "create" ? "Créer" : "Rejoindre"}</Button>
        </div>
      </div>
    </Card>
  );
}

function GroupPage({ group, back }: { group: Group; back: () => void }) {
  const { store } = useData();
  const [presence, setPresence] = useState<Presence[]>([]);
  const [board, setBoard] = useState<LeaderboardRow[]>([]);
  const [members, setMembers] = useState<Member[]>([]);
  const [error, setError] = useState<string | null>(null);
  const [copied, setCopied] = useState(false);
  const [now, setNow] = useState(() => new Date());

  const load = useCallback(async () => {
    try {
      // Mon temps des deux dernières semaines, pour que le classement soit juste.
      if (store) {
        const subjects = new Set(group.courses);
        const counting = readCounting();
        const logs = store.fetch(StudySession)
          .filter((s) => s.course && countsSession(counting, s) && (subjects.size === 0 || subjects.has(s.course.code) || subjects.has(s.course.displayCode)))
          .map((s) => ({ courseCode: s.course?.code ?? "", taskType: s.taskTypeRaw, startedAt: s.startedAt, durationSeconds: s.durationSeconds }));
        await Groups.replaceStudyLogs(group.id, logs).catch(() => {});
      }
      const [p, b, m] = await Promise.all([Groups.presence(group.id), Groups.leaderboard(group.id).catch(() => []), Groups.members(group.id)]);
      setPresence(p); setBoard(b); setMembers(m); setError(null);
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    }
  }, [group, store]);
  useEffect(() => {
    void load();
    // Relu toutes les minutes tant que la page est ouverte (« qui travaille »).
    const id = window.setInterval(() => { setNow(new Date()); void load(); }, 60_000);
    return () => window.clearInterval(id);
  }, [load]);

  return (
    <div className="page">
      <PageHeader title={group.name} subtitle={group.courses.join(" · ") || "Toutes matières"}
        actions={<>
          <Button icon="chevron.left" onClick={back}>Groupes</Button>
          <Button icon="doc.on.doc" onClick={() => { void navigator.clipboard?.writeText(group.inviteCode); setCopied(true); }}>
            {copied ? "Copié" : `Code ${group.inviteCode}`}
          </Button>
        </>} />
      {error && <p className="settings-error">{error}</p>}
      <Section title="En ce moment">
        <Card>
          {presence.length === 0 ? <p className="faint" style={{ margin: 0 }}>Personne ne travaille en ce moment.</p> : presence.map((entry) => (
            <div key={entry.userID} style={{ display: "flex", alignItems: "center", gap: 10, padding: "6px 0" }}>
              <span style={{ width: 8, height: 8, borderRadius: 4, background: "var(--correct)" }} />
              <span style={{ fontWeight: 600 }}>{entry.isMe ? "Toi" : entry.displayName}</span>
              <span className="faint" style={{ flex: 1 }}>{[entry.courseCode, entry.taskLabel, entry.target].filter(Boolean).join(" · ") || "Travail en cours"}</span>
              <span className="mono faint">{hours((now.getTime() - entry.startedAt.getTime()) / 1000)}</span>
            </div>
          ))}
        </Card>
      </Section>
      <Section title="Cette semaine">
        <Card>
          {board.length === 0 ? <p className="faint" style={{ margin: 0 }}>Pas encore de temps compté cette semaine.</p> : board.map((row, index) => (
            <div key={row.userID} style={{ display: "flex", alignItems: "center", gap: 10, padding: "6px 0" }}>
              <span className="mono faint" style={{ width: 20 }}>{index + 1}</span>
              <span style={{ flex: 1 }}>{row.displayName}</span>
              {row.seriesCompleted > 0 && <span className="faint" style={{ fontSize: 12 }}>{row.seriesCompleted} séries</span>}
              <span className="mono">{hours(row.weeklySeconds)}</span>
            </div>
          ))}
        </Card>
      </Section>
      <Section title={`Membres · ${members.length}`}>
        <Card>
          {members.map((member) => (
            <div key={member.userID} style={{ display: "flex", gap: 8, padding: "4px 0" }}>
              <Icon name="person" size={14} />
              <span style={{ flex: 1 }}>{member.displayName}</span>
              {member.role === "admin" && <span className="faint" style={{ fontSize: 12 }}>admin</span>}
            </div>
          ))}
        </Card>
      </Section>
      <Button icon="rectangle.portrait.and.arrow.right" onClick={() => {
        if (!window.confirm(`Quitter « ${group.name} » ?`)) return;
        void Groups.leave(group.id).then(back, (e: unknown) => setError(e instanceof Error ? e.message : String(e)));
      }}>Quitter le groupe</Button>
      <p className="faint" style={{ fontSize: 12, marginTop: 12 }}>Mis à jour {DateUtils.time(now)}.</p>
    </div>
  );
}
