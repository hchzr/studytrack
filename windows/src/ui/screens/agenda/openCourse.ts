// Ouvrir un cours depuis l'agenda (le `open(courseID, targetID)` du Mac), sans
// faire descendre la fonction à travers chaque case de la grille.

import { createContext, useContext } from "react";

export type OpenCourse = (courseID: string, targetID?: string | null) => void;

export const OpenCourseContext = createContext<OpenCourse | null>(null);

export function useOpenCourse(): OpenCourse | null {
  return useContext(OpenCourseContext);
}
