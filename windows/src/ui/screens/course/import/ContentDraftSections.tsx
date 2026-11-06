// Les sections d'un brouillon de cours, semaine par semaine, à corriger
// (Polymestre/Views/Courses/ContentImport.swift › ContentDraftSections).

import { Checkbox, Icon, Select, cx } from "../../../kit.tsx";
import { ContentDraft, ContentDraftItem, ContentDraftSection, ContentItemKind } from "../../../../domain/courseContentImport.ts";
import { ContentDraftBuilder } from "../../../../domain/courseContentImport.ts";
import { DateUtils } from "../../../../domain/dateUtils.ts";
import { Plural } from "../../../../domain/plural.ts";
import { MathText } from "../common.tsx";

/** Le résumé d'un brouillon en une ligne (`ContentDraftSummary.line`). */
export function summaryLine(draft: ContentDraft): string {
  const parts: string[] = [];
  const n = (count: number, one: string, many: string) => Plural.count(count, `${count} ${one}`, `${count} ${many}`);
  if (draft.theoryCount > 0) parts.push(`${n(draft.theoryCount, "élément", "éléments")} de théorie`);
  if (draft.videoCount > 0) parts.push(n(draft.videoCount, "vidéo", "vidéos"));
  if (draft.seriesCount > 0) parts.push(n(draft.seriesCount, "série", "séries"));
  if (draft.deadlineCount > 0) parts.push(n(draft.deadlineCount, "échéance", "échéances"));
  if (draft.resourceCount > 0) parts.push(n(draft.resourceCount, "document", "documents"));
  return parts.length === 0 ? "rien de reconnaissable" : parts.join(" · ");
}

export function ContentDraftSections({ draft, totalWeeks, onChange }: {
  draft: ContentDraft; totalWeeks: number; onChange: () => void;
}) {
  return (
    <>
      {draft.sections.map((section) => (
        <SectionBlock key={section.id} section={section} totalWeeks={totalWeeks} onChange={onChange} />
      ))}
    </>
  );
}

function SectionBlock({ section, totalWeeks, onChange }: { section: ContentDraftSection; totalWeeks: number; onChange: () => void }) {
  const range = section.weekRange;
  const options = [{ value: "0", label: "Non planifié" },
    ...Array.from({ length: Math.max(totalWeeks, section.week, 1) }, (_, i) => ({ value: String(i + 1), label: `Commence en semaine ${i + 1}` }))];
  const rangeLabel = range === null ? "Non planifié"
    : range.lower === range.upper ? `Semaine ${range.lower}` : `Semaines ${range.lower}–${range.upper}`;

  return (
    <section className="imp-block">
      <div className="imp-section-head">
        <Checkbox checked={section.isIncluded} ariaLabel={section.title === "" ? "Sans titre" : section.title}
          onChange={(value) => { section.isIncluded = value; onChange(); }}
          label={<strong><MathText text={section.title === "" ? "Sans titre" : section.title} /></strong>} />
      </div>
      {section.isIncluded && (
        <>
          <div className="imp-week">
            <Icon name="calendar" size={14} />
            <span>{rangeLabel}</span>
            {section.weekIsInferred && <span className="faint">proposée</span>}
            <span className="spacer" />
            {/* La changer **décale** tout le chapitre, étalement compris. */}
            <Select ariaLabel="Semaine de la section" value={String(section.week)} options={options}
              onChange={(value) => {
                const week = Number(value);
                section.shiftWeeks(week - section.week, totalWeeks);
                section.week = week;
                section.weekIsInferred = false;
                onChange();
              }} />
          </div>
          <div className="imp-exercises">
            {section.items.map((item) => (
              <ItemRow key={item.id} item={item} section={section} onChange={onChange} />
            ))}
          </div>
        </>
      )}
    </section>
  );
}

function ItemRow({ item, section, onChange }: { item: ContentDraftItem; section: ContentDraftSection; onChange: () => void }) {
  const ignored = item.kind === "ignore";
  const questions = item.exercises.reduce((total, e) => total + Math.max(e.questions.length, 1), 0);
  const details = [
    item.kind === "series" && item.title !== `Série ${item.number}` ? item.title : null,
    item.kind === "series" && item.exercises.length > 0 ? `${item.exercises.length} exercices, ${questions} questions` : null,
    item.kind === "series" && item.pdfURL !== "" && item.exercises.length === 0 ? "PDF à lire" : null,
    item.solutionsAt ? `corrigé le ${DateUtils.shortDay(item.solutionsAt)}` : null,
    item.kind === "theory" && item.videoCount > 0 ? Plural.count(item.videoCount, `${item.videoCount} vidéo`, `${item.videoCount} vidéos`) : null,
    item.week !== null && item.week !== section.week && !ignored ? `semaine ${item.plannedWeek(section)}` : null,
  ].filter((part): part is string => part !== null);

  return (
    <div className="imp-ex">
      <div className="imp-ex-row">
        <span className="imp-ex-main imp-item">
          <Icon name={item.kind === "series" ? "checklist" : item.kind === "deadline" ? "calendar.badge.clock" : "play.rectangle.fill"} size={16} />
          <span className="imp-sum-text">
            <span className={cx("imp-sum-title", ignored && "faint")}>
              <MathText text={item.kind === "series" ? `Série ${item.number}` : `${item.number} · ${item.title}`} />
            </span>
            {details.length > 0 && <span className="imp-sum-outline">{details.join(" · ")}</span>}
          </span>
        </span>
        <Select ariaLabel="Type" value={item.kind}
          options={ContentItemKind.allCases.map((kind) => ({ value: kind, label: ContentItemKind.label(kind) }))}
          onChange={(kind) => {
            item.kind = kind;
            if (kind === "series" && item.seriesNumber === null) {
              const last = Number(item.number.split(".").pop());
              item.seriesNumber = ContentDraftBuilder.seriesNumber(item.title) ?? (Number.isInteger(last) && last > 0 ? last : 1);
              item.number = String(item.seriesNumber);
            }
            onChange();
          }} />
      </div>
    </div>
  );
}
