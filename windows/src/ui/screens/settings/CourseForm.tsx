// Le formulaire d'un cours (CourseFormView.swift), en version compacte pour le
// bureau : les champs essentiels, la charge hebdomadaire, la section, la couleur
// et le semestre. Les heures de travail personnel déduites des ECTS restent au
// moteur de charge : ce formulaire ne les invente pas.

import { useState, type FormEvent, type ReactNode } from "react";
import { AcademicTerm, Course, EPFLCatalog } from "../../../models/index.ts";
import { useData } from "../../../data/dataContext.tsx";
import { Button, Select, Stepper, Switch } from "../../kit.tsx";

interface CourseFormProps {
  /** `null` : création. */
  course: Course | null;
  terms: AcademicTerm[];
  defaultSectionCode: string;
  onClose: () => void;
}

function Field({ label, children }: { label: string; children: ReactNode }) {
  return (
    <label className="settings-form-field">
      <span>{label}</span>
      {children}
    </label>
  );
}

export function CourseForm({ course, terms, defaultSectionCode, onClose }: CourseFormProps) {
  const { save } = useData();
  const [code, setCode] = useState(course?.code ?? "");
  const [name, setName] = useState(course?.name ?? "");
  const [shortName, setShortName] = useState(course?.shortName ?? "");
  const [lecturer, setLecturer] = useState(course?.lecturer ?? "");
  const [credits, setCredits] = useState(course?.credits ?? 4);
  const [hasLectures, setHasLectures] = useState(course?.hasLectures ?? true);
  const [lectureHours, setLectureHours] = useState(course?.weeklyLectureHours ?? 2);
  const [exerciseHours, setExerciseHours] = useState(course?.weeklyExerciseHours ?? 1);
  const [colorHex, setColorHex] = useState(course?.colorHex ?? "#4F46E5");
  const [sectionCode, setSectionCode] = useState(course?.sectionCode ?? defaultSectionCode);
  const [selectedTermId, setSelectedTermId] = useState(
    () => course?.term?.id ?? AcademicTerm.resolve(terms)?.id ?? terms[0]?.id ?? "",
  );
  const [isTracked, setIsTracked] = useState(course?.isTracked ?? true);
  const [link, setLink] = useState(course?.moodleURLString ?? "");
  const [saving, setSaving] = useState(false);

  const submit = async (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    const trimmedCode = code.trim().toUpperCase();
    if (trimmedCode === "" || saving) return;
    setSaving(true);
    const resolvedName = name.trim() === "" ? trimmedCode : name.trim();
    const chosenTerm = terms.find((candidate) => candidate.id === selectedTermId)
      ?? AcademicTerm.resolve(terms);

    if (course) {
      course.code = trimmedCode;
      course.name = resolvedName;
      course.shortName = shortName.trim();
      course.credits = credits;
      course.hasLectures = hasLectures;
      course.weeklyLectureHours = hasLectures ? lectureHours : 0;
      course.weeklyExerciseHours = exerciseHours;
      course.colorHex = colorHex;
      course.sectionCode = sectionCode;
      course.lecturer = lecturer.trim();
      course.moodleURLString = link.trim();
      course.isTracked = isTracked;
      if (chosenTerm) course.term = chosenTerm;
      await save(course);
    } else {
      const created = new Course({
        code: trimmedCode,
        name: resolvedName,
        shortName: shortName.trim(),
        credits,
        colorHex,
        term: chosenTerm,
        weeklyLectureHours: hasLectures ? lectureHours : 0,
        weeklyExerciseHours: exerciseHours,
        hasLectures,
        sectionCode,
        isTracked,
        lecturer: lecturer.trim(),
        moodleURLString: link.trim(),
      });
      await save(created);
    }
    setSaving(false);
    onClose();
  };

  return (
    <form className="settings-form" onSubmit={(event) => void submit(event)}>
      <div className="settings-form-head">
        <h3 className="serif">{course ? "Modifier le cours" : "Nouveau cours"}</h3>
        <p className="settings-hint">Les champs essentiels d'abord ; les heures suivent « ce cours a des heures d'amphi ».</p>
      </div>

      <div className="settings-form-grid">
        <Field label="Code (ex : CS-250)">
          <input className="field" value={code} autoFocus
            onChange={(event) => setCode(event.target.value)} />
        </Field>
        <Field label="Nom du cours">
          <input className="field" value={name}
            onChange={(event) => setName(event.target.value)} />
        </Field>
        <Field label="Abréviation (ex : ALGO)">
          <input className="field" value={shortName}
            onChange={(event) => setShortName(event.target.value)} />
        </Field>
        <Field label="Enseignant (optionnel)">
          <input className="field" value={lecturer}
            onChange={(event) => setLecturer(event.target.value)} />
        </Field>
      </div>

      <div className="settings-form-switches">
        <Switch checked={hasLectures} label="Ce cours a des heures de cours (amphi)"
          onChange={setHasLectures} />
        <Switch checked={isTracked} label="Suivre ce cours" onChange={setIsTracked} />
      </div>

      <div className="settings-form-grid">
        {hasLectures && (
          <div className="settings-form-field">
            <span>Heures d'amphi / semaine</span>
            <Stepper value={lectureHours} min={0} max={20} step={0.5} label="Heures d'amphi"
              format={(value) => `${String(value).replace(".", ",")} h`} onChange={setLectureHours} />
          </div>
        )}
        <div className="settings-form-field">
          <span>Heures d'exercices / semaine</span>
          <Stepper value={exerciseHours} min={0} max={20} step={0.5} label="Heures d'exercices"
            format={(value) => `${String(value).replace(".", ",")} h`} onChange={setExerciseHours} />
        </div>
        <div className="settings-form-field">
          <span>Crédits</span>
          <Stepper value={credits} min={1} max={40} label="Crédits"
            format={(value) => `${value} ECTS`} onChange={setCredits} />
        </div>
      </div>

      <div className="settings-form-grid">
        <Field label="Section EPFL">
          <Select value={sectionCode} ariaLabel="Section EPFL" onChange={setSectionCode}
            options={[
              { value: "", label: "Non renseignée" },
              ...EPFLCatalog.sections.map((section) => ({
                value: section.code, label: `${section.name} (${section.code})`,
              })),
            ]} />
        </Field>
        <Field label="Semestre">
          {terms.length === 0
            ? <span className="settings-value">Aucun semestre</span>
            : (
              <Select value={selectedTermId} ariaLabel="Semestre" onChange={setSelectedTermId}
                options={terms.map((term) => ({ value: term.id, label: term.displayName }))} />
            )}
        </Field>
        <Field label="Couleur">
          <input className="settings-color" type="color" value={colorHex}
            aria-label="Couleur du cours"
            onChange={(event) => setColorHex(event.target.value)} />
        </Field>
        <Field label="Lien (optionnel)">
          <input className="field" type="text" inputMode="url" placeholder="https://…" value={link}
            onChange={(event) => setLink(event.target.value)} />
        </Field>
      </div>

      <div className="settings-actions">
        <Button onClick={onClose}>Annuler</Button>
        <Button type="submit" variant="primary" disabled={code.trim() === "" || saving}>
          {course ? "Enregistrer" : "Créer"}
        </Button>
      </div>
    </form>
  );
}
