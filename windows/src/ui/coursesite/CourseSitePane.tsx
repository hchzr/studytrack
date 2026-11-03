// Le volet « Le cours » (CoursePane du Mac, restreint pour l'instant au site Botafogo) :
// le site du cours lu dans l'app, sans navigateur. La page ouverte est retenue par cours.

import { useState } from "react";
import type { Course } from "../../models/course.ts";
import { BotafogoCourse, type BotafogoLocation } from "../botafogo/BotafogoCourse.tsx";
import { openInApp } from "../studymode/openers.ts";
import { botafogoSite } from "./courseSites.ts";

const opened = new Map<string, BotafogoLocation | null>();

export function CourseSitePane({ course, tint }: { course: Course | null; tint: string }) {
  const site = botafogoSite(course);
  const [location, setLocation] = useState<BotafogoLocation | null>(() => (course ? opened.get(course.id) ?? null : null));
  if (!course || !site) {
    return (
      <div className="bf-center">
        <span className="serif" style={{ fontSize: 20, color: "var(--ink)" }}>Pas de site pour ce cours</span>
        <span>Ajoute l'adresse du site (Botafogo) dans « Modifier le cours › Sources ».</span>
      </div>
    );
  }
  return (
    <BotafogoCourse
      site={site}
      tint={tint}
      openWeb={(url) => { void openInApp(url, course.displayCode); }}
      location={location}
      onLocation={(next) => { opened.set(course.id, next); setLocation(next); }}
    />
  );
}
