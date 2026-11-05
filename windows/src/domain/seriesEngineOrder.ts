// La nature d'un moteur d'analyse de PDF et l'ordre dans lequel on l'essaie
// (StudyTrack/Domain/SeriesEngineOrder.swift).
//
// Séparé du service pour que l'ordre de préférence soit une fonction pure, donc
// testable sans modèle, sans réseau et sans base. Cet ordre a déjà été inversé une
// fois — le modèle embarqué passait avant le modèle servi — et rien ne l'aurait
// signalé.

/// La nature d'un moteur d'analyse de PDF, **sans ce qu'il lui faut pour tourner**.
export type SeriesEngineKind = "shared" | "onDevice";

export const SeriesEngineKind = {
  allCases: ["shared", "onDevice"] as readonly SeriesEngineKind[],

  label(kind: SeriesEngineKind): string {
    switch (kind) {
      case "shared": return "IA Polymestre";
      case "onDevice": return "IA sur l'appareil";
    }
  },
};

/// L'ordre dans lequel les moteurs sont essayés.
///
/// **Le service d'abord, le modèle embarqué ensuite.** L'ordre inverse semblait
/// prudent — gratuit, privé, hors ligne — mais il plaçait un modèle de quelques
/// milliards de paramètres devant un modèle servi, sur une tâche qu'il rate
/// souvent : numéros manqués, intitulés inventés, énoncés confondus avec des
/// titres. Relire ce travail coûte plus de temps qu'il n'en fait gagner.
///
/// Le modèle embarqué garde sa place : il prend le relais **hors ligne**, quand la
/// fonction n'est pas déployée, ou quand le réseau manque. Un résultat imparfait
/// vaut mieux que pas de résultat du tout.
export const SeriesEngineOrder = {
  engines(sharedAvailable: boolean, onDeviceAvailable: boolean): SeriesEngineKind[] {
    const result: SeriesEngineKind[] = [];
    if (sharedAvailable) result.push("shared");
    if (onDeviceAvailable) result.push("onDevice");
    return result;
  },
};
