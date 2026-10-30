import { PageHeader, Placeholder } from "../kit.tsx";

export function SettingsScreen() {
  return (
    <>
      <PageHeader title="Settings" />
      <Placeholder screen="Settings" from="Views/Stats/*Settings* (Mac : MacSettingsView.swift)" />
    </>
  );
}
