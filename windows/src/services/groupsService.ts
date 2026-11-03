// Les groupes d'étude (SocialService + GroupSync + PresenceService de l'iPhone) : créer ou
// rejoindre un groupe par son code, ses membres, le classement de la semaine, qui travaille en
// ce moment — et, pendant que mon chrono tourne, ma présence (un battement toutes les cinq
// minutes, effacé à l'arrêt). Les tables et règles du serveur sont celles de l'iPhone.
// Sur le même compte que la synchronisation (`syncService.supabase`).

import { syncService } from "./syncService.ts";
import type { SupabaseClient } from "./supabase.ts";
import { SupabaseError } from "./supabase.ts";

export interface Group { id: string; name: string; description: string; inviteCode: string; createdBy: string | null; courses: string[]; role: string }
export interface Member { userID: string; role: string; displayName: string }
export interface LeaderboardRow { userID: string; displayName: string; weeklySeconds: number; totalSeconds: number; seriesCompleted: number }
export interface Presence { userID: string; displayName: string; courseCode: string; taskLabel: string; target: string; startedAt: Date; updatedAt: Date; isMe: boolean }

export const PRESENCE_HEARTBEAT_S = 300;

async function client(): Promise<{ api: SupabaseClient; me: string }> {
  const api = syncService.supabase;
  if (!api) throw new Error("Ce build n'a pas de serveur.");
  const me = await api.userId();
  if (!me) throw new Error("Connecte-toi d'abord (Réglages › Compte et synchronisation).");
  return { api, me };
}

const q = encodeURIComponent;

/* eslint-disable @typescript-eslint/no-explicit-any */
function toGroup(raw: any, role = "member"): Group {
  return {
    id: raw.id, name: raw.name ?? "", description: raw.description ?? "", inviteCode: raw.invite_code ?? "",
    createdBy: raw.created_by ?? null, role,
    courses: Array.isArray(raw.group_courses) ? raw.group_courses.map((c: any) => c.course_code).filter(Boolean)
      : raw.course_code ? [raw.course_code] : [],
  };
}

/** « EPFL-7K2Q » : le code qu'on partage pour inviter (StudyGroup.generateInviteCode). */
export function makeInviteCode(): string {
  const alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
  const bytes = crypto.getRandomValues(new Uint8Array(4));
  return "EPFL-" + Array.from(bytes, (b) => alphabet[b % alphabet.length]).join("");
}

/** Un code collé : majuscules, sans espaces. */
export function normalizeInviteCode(text: string): string {
  return text.trim().toUpperCase().replace(/\s+/g, "");
}

async function ensureProfile(api: SupabaseClient, me: string, displayName: string): Promise<void> {
  if (!displayName.trim()) return;
  try {
    await api.request("/rest/v1/profiles?on_conflict=id", {
      method: "POST", body: [{ id: me, display_name: displayName.trim() }], prefer: "resolution=merge-duplicates,return=minimal",
    });
  } catch { /* le profil existe déjà, ou la table refuse : l'adhésion le dira */ }
}

/** Mon adhésion (jamais un upsert : la mise à jour est réservée aux administrateurs ; 23505 = déjà membre). */
async function ensureMembership(api: SupabaseClient, me: string, groupID: string, role: "admin" | "member"): Promise<void> {
  try {
    await api.request("/rest/v1/group_members", { method: "POST", body: { group_id: groupID, user_id: me, role }, prefer: "return=minimal" });
  } catch (error) {
    if (error instanceof SupabaseError && (error.status === 409 || /23505|duplicate/i.test(error.message))) return;
    throw error;
  }
}

export const Groups = {
  async mine(): Promise<Group[]> {
    const { api, me } = await client();
    const rows = await api.request<any[]>(`/rest/v1/group_members?user_id=eq.${me}&select=role,study_groups(*,group_courses(course_code))`);
    return (rows ?? []).filter((row) => row.study_groups).map((row) => toGroup(row.study_groups, row.role));
  },

  async create(name: string, courseCodes: string[], displayName: string): Promise<Group> {
    const { api, me } = await client();
    await ensureProfile(api, me, displayName);
    const subjects = [...new Set(courseCodes.map((c) => c.trim().toUpperCase()).filter(Boolean))];
    const rows = await api.request<any[]>("/rest/v1/study_groups", {
      method: "POST", prefer: "return=representation",
      body: { name: name.trim(), description: "", course_code: subjects[0] ?? "", invite_code: makeInviteCode(), created_by: me },
    });
    const group = rows?.[0];
    if (!group) throw new Error("Le serveur n'a pas créé le groupe.");
    await ensureMembership(api, me, group.id, "admin");
    if (subjects.length > 0) {
      try {
        await api.request("/rest/v1/group_courses", { method: "POST", body: subjects.map((code) => ({ group_id: group.id, course_code: code })), prefer: "return=minimal" });
        await api.request("/rest/v1/member_courses", { method: "POST", body: subjects.map((code) => ({ group_id: group.id, user_id: me, course_code: code })), prefer: "return=minimal" });
      } catch { /* les matières se règlent ensuite */ }
    }
    return toGroup({ ...group, group_courses: subjects.map((code) => ({ course_code: code })) }, "admin");
  },

  async join(inviteCode: string, displayName: string): Promise<Group> {
    const { api, me } = await client();
    await ensureProfile(api, me, displayName);
    const rows = await api.request<any[]>(`/rest/v1/study_groups?invite_code=eq.${q(normalizeInviteCode(inviteCode))}&select=*`);
    const group = rows?.[0];
    if (!group) throw new Error("Aucun groupe avec ce code.");
    await ensureMembership(api, me, group.id, "member");
    // Toutes les matières du groupe par défaut (après l'adhésion : la lecture l'exige).
    try {
      const courses = await api.request<any[]>(`/rest/v1/group_courses?group_id=eq.${group.id}&select=course_code`);
      const codes = (courses ?? []).map((c) => c.course_code).filter(Boolean);
      if (codes.length > 0) {
        await api.request("/rest/v1/member_courses", { method: "POST", body: codes.map((code: string) => ({ group_id: group.id, user_id: me, course_code: code })), prefer: "resolution=ignore-duplicates,return=minimal" });
      }
      group.group_courses = codes.map((code: string) => ({ course_code: code }));
    } catch { /* idem */ }
    return toGroup(group, "member");
  },

  async leave(groupID: string): Promise<void> {
    const { api, me } = await client();
    await api.request(`/rest/v1/group_members?group_id=eq.${groupID}&user_id=eq.${me}`, { method: "DELETE" });
  },

  async members(groupID: string): Promise<Member[]> {
    const { api } = await client();
    const rows = await api.request<any[]>(`/rest/v1/group_members?group_id=eq.${groupID}&select=user_id,role,profiles(display_name)`);
    return (rows ?? []).map((row) => ({ userID: row.user_id, role: row.role, displayName: row.profiles?.display_name ?? "Membre" }));
  },

  async leaderboard(groupID: string): Promise<LeaderboardRow[]> {
    const { api } = await client();
    const rows = await api.request<any[]>("/rest/v1/rpc/group_leaderboard", { method: "POST", body: { p_group_id: groupID } });
    return (rows ?? []).map((row) => ({
      userID: row.user_id, displayName: row.display_name ?? "Membre", weeklySeconds: row.weekly_seconds ?? 0,
      totalSeconds: row.total_seconds ?? 0, seriesCompleted: row.series_completed ?? 0,
    })).sort((a, b) => b.weeklySeconds - a.weeklySeconds);
  },

  /** Qui travaille en ce moment (un battement il y a moins de 12 minutes), moi d'abord. */
  async presence(groupID: string): Promise<Presence[]> {
    const { api, me } = await client();
    const rows = await api.request<any[]>(`/rest/v1/presence?group_id=eq.${groupID}&select=*,profiles(display_name)`);
    const now = Date.now();
    return (rows ?? []).map((row) => ({
      userID: row.user_id, displayName: row.profiles?.display_name ?? "Membre", courseCode: row.course_code ?? "",
      taskLabel: row.task_label ?? "", target: row.target ?? "", startedAt: new Date(row.started_at), updatedAt: new Date(row.updated_at),
      isMe: row.user_id === me,
    })).filter((entry) => now - entry.updatedAt.getTime() < PRESENCE_HEARTBEAT_S * 2.4 * 1000)
      .sort((a, b) => Number(b.isMe) - Number(a.isMe) || a.startedAt.getTime() - b.startedAt.getTime());
  },

  /** Ma présence dans mes groupes (`null` : je m'arrête — seulement ma ligne est effacée). */
  async publishPresence(entry: { courseCode: string; taskLabel: string; target: string; startedAt: Date; displayName: string } | null, groupIDs: string[]): Promise<void> {
    if (groupIDs.length === 0) return;
    const { api, me } = await client();
    for (const groupID of groupIDs) {
      if (!entry) {
        await api.request(`/rest/v1/presence?group_id=eq.${groupID}&user_id=eq.${me}`, { method: "DELETE" });
        continue;
      }
      const row = {
        group_id: groupID, user_id: me, course_code: entry.courseCode, task_label: entry.taskLabel, target: entry.target,
        started_at: entry.startedAt.toISOString(), updated_at: new Date().toISOString(),
      };
      try {
        await api.request("/rest/v1/presence?on_conflict=group_id,user_id", { method: "POST", body: [row], prefer: "resolution=merge-duplicates,return=minimal" });
      } catch (error) {
        // Adhésion ou profil manquant côté serveur : on répare, puis on réessaie une fois.
        if (!(error instanceof SupabaseError) || !/row-level|42501|23503/i.test(error.message)) throw error;
        await ensureProfile(api, me, entry.displayName);
        await ensureMembership(api, me, groupID, "member");
        await api.request("/rest/v1/presence?on_conflict=group_id,user_id", { method: "POST", body: [row], prefer: "resolution=merge-duplicates,return=minimal" });
      }
    }
  },

  /** Mon temps des 14 derniers jours dans un groupe (remplacé, jamais empilé), pour le classement. */
  async replaceStudyLogs(groupID: string, logs: { courseCode: string; taskType: string; startedAt: Date; durationSeconds: number }[]): Promise<void> {
    const { api, me } = await client();
    const since = new Date(Date.now() - 14 * 86_400_000);
    await api.request(`/rest/v1/study_log_public?group_id=eq.${groupID}&user_id=eq.${me}&started_at=gte.${q(since.toISOString())}`, { method: "DELETE" });
    const rows = logs.filter((log) => log.startedAt >= since).map((log) => ({
      user_id: me, group_id: groupID, course_code: log.courseCode, task_type: log.taskType,
      started_at: log.startedAt.toISOString(), duration_seconds: Math.round(log.durationSeconds),
    }));
    if (rows.length > 0) await api.request("/rest/v1/study_log_public", { method: "POST", body: rows, prefer: "resolution=ignore-duplicates,return=minimal" });
  },
};
