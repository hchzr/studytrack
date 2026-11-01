// Réglages — les préférences du poste, le semestre et ses cours, l'état du
// compte et de la synchronisation. Porté de `MacSettingsView`/`MacSettings`,
// `SchoolSetupView` et `ProfileView`/`ConnectionsView` : les réglages propres
// au Mac (barre des menus, mode étude, Claude) n'ont pas d'équivalent ici.

import { PageHeader } from "../kit.tsx";
import { AppearanceSection } from "./settings/AppearanceSection.tsx";
import { TermSection } from "./settings/TermSection.tsx";
import { CoursesSection } from "./settings/CoursesSection.tsx";
import { SyncSection } from "./settings/SyncSection.tsx";
import { AccountSection } from "./settings/AccountSection.tsx";
import "./settings/settings.css";

export function SettingsScreen() {
  return (
    <div className="settings-screen">
      <PageHeader title="Réglages" subtitle="Apparence, semestre, cours et comptes." />
      <AppearanceSection />
      <TermSection />
      <CoursesSection />
      <SyncSection />
      <AccountSection />
    </div>
  );
}
