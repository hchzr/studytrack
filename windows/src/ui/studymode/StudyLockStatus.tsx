// La ligne « Blocage » du mode étude : ce que Rust dit tenir réellement (apps
// surveillées, sites coupés, ou pourquoi pas). Rien n'est affiché hors de l'app.

import { useSyncExternalStore } from "react";
import { inNative } from "../../native/tauri.ts";
import { lockStatusLine, studyLockStatus } from "../../native/studyLock.ts";

export function StudyLockStatus({ wanted }: { wanted: boolean }) {
  const report = useSyncExternalStore(studyLockStatus.subscribe, studyLockStatus.snapshot);
  const line = lockStatusLine(report, wanted, inNative());
  if (line === null) return null;
  return (
    <div role="status" style={{
      padding: "4px 16px", fontSize: 12, color: "var(--ink-secondary)",
      borderBottom: "1px solid var(--rule)", flexShrink: 0,
    }}>
      {line}
    </div>
  );
}
