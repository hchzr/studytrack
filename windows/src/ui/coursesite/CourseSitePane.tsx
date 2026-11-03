// Le volet « Le cours » (CoursePane du Mac) : les sites du cours lus dans l'app — Botafogo
// (semaines, polycopié) et Moodle (sections, activités, documents, forums). Une source à la
// fois ; ce qui est ouvert est retenu par cours le temps de la session.

import { useState } from "react";
import type { Course } from "../../models/course.ts";
import { BotafogoCourse, type BotafogoLocation } from "../botafogo/BotafogoCourse.tsx";
import { Segmented } from "../kit.tsx";
import { openInApp } from "../studymode/openers.ts";
import { EdView } from "./EdView.tsx";
import { MoodleCourseView, type MoodleReading } from "./MoodleCourseView.tsx";
import { botafogoSite, courseSources, coursewareKey, moodleCourseID, type CourseSource } from "./courseSites.ts";
import { CoursewareView } from "./CoursewareView.tsx";
import { MediaSpaceOverlay } from "../media/MediaSpaceOverlay.tsx";
import { isMediaSpaceVideo } from "../../services/mediaspace.ts";
import "./coursesite.css";

interface Remembered { source: CourseSource; botafogo: BotafogoLocation | null; moodle: MoodleReading | null }
const remembered = new Map<string, Remembered>();

const LABEL: Record<CourseSource, string> = { botafogo: "Le cours", moodle: "Moodle", courseware: "Courseware", ed: "Ed" };

export function CourseSitePane({ course, tint }: { course: Course | null; tint: string }) {
  const sources = courseSources(course);
  const [video, setVideo] = useState<string | null>(null);
  const [state, setState] = useState<Remembered>(() =>
    (course ? remembered.get(course.id) : undefined) ?? { source: sources[0] ?? "botafogo", botafogo: null, moodle: null });
  const update = (patch: Partial<Remembered>) => {
    const next = { ...state, ...patch };
    if (course) remembered.set(course.id, next);
    setState(next);
  };

  if (!course || sources.length === 0) {
    return (
      <div className="bf-center">
        <span className="serif" style={{ fontSize: 20, color: "var(--ink)" }}>Pas de site pour ce cours</span>
        <span>Ajoute le lien Moodle ou l'adresse du site (Botafogo) dans « Modifier le cours ».</span>
      </div>
    );
  }
  const source = sources.includes(state.source) ? state.source : sources[0];
  // Une vidéo MediaSpace se lit ici même ; le reste s'ouvre dans une fenêtre de l'app.
  const openWeb = (url: string) => {
    if (isMediaSpaceVideo(url)) setVideo(url);
    else void openInApp(url, course.displayCode);
  };
  const site = botafogoSite(course);
  const moodle = moodleCourseID(course);
  return (
    <div className="cs-pane" style={{ ["--bf-tint" as string]: tint }}>
      {sources.length > 1 && (
        <div className="cs-sources">
          <Segmented<CourseSource> ariaLabel="Source du cours" value={source} onChange={(value) => update({ source: value })}
            options={sources.map((value) => ({ value, label: LABEL[value] }))} />
        </div>
      )}
      <div className="cs-body">
        {source === "botafogo" && site && (
          <BotafogoCourse site={site} tint={tint} openWeb={openWeb}
            location={state.botafogo} onLocation={(botafogo) => update({ botafogo })} />
        )}
        {source === "ed" && <EdView code={course.code} openWeb={openWeb} />}
        {source === "courseware" && coursewareKey(course) && <CoursewareView courseKey={coursewareKey(course)!} openWeb={openWeb} />}
        {source === "moodle" && moodle !== null && (
          <MoodleCourseView courseID={moodle} title={course.name} openWeb={openWeb}
            reading={state.moodle} onReading={(value) => update({ moodle: value })} />
        )}
      </div>
      {video && <MediaSpaceOverlay link={video} close={() => setVideo(null)} openWeb={(url) => { void openInApp(url, course.displayCode); }} />}
    </div>
  );
}
