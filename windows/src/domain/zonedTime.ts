// Le temps d'un fuseau, sans bibliothèque : lire les composantes d'une date dans un
// fuseau IANA, et refaire une date depuis une heure murale (`Calendar` de Foundation
// avec `timeZone`). Sert à l'horaire iCalendar, dont les événements portent leur
// `TZID` : un cours de 08:15 à Zurich reste un cours de 08:15 pour une machine réglée
// ailleurs.

export interface WallTime {
  year: number;
  month: number; // 1…12
  day: number;
  hour: number;
  minute: number;
  second: number;
  /** 1 = dimanche … 7 = samedi (convention iCalendar et `Calendar`). */
  weekday: number;
}

const formatters = new Map<string, Intl.DateTimeFormat>();

function formatter(timeZone: string): Intl.DateTimeFormat {
  let found = formatters.get(timeZone);
  if (!found) {
    found = new Intl.DateTimeFormat("en-US", {
      timeZone, hourCycle: "h23", year: "numeric", month: "numeric", day: "numeric",
      hour: "numeric", minute: "numeric", second: "numeric", weekday: "short",
    });
    formatters.set(timeZone, found);
  }
  return found;
}

/** Un identifiant de fuseau connu de la plate-forme, sinon `null` (`TimeZone(identifier:)`). */
export function validTimeZone(identifier: string | null | undefined): string | null {
  if (!identifier) return null;
  try {
    new Intl.DateTimeFormat("en-US", { timeZone: identifier });
    return identifier;
  } catch {
    return null;
  }
}

const weekdays = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];

/** Les composantes d'une date dans un fuseau — le fuseau local quand il n'y en a pas. */
export function wallTime(date: Date, timeZone: string | null = null): WallTime {
  if (timeZone === null) {
    return {
      year: date.getFullYear(), month: date.getMonth() + 1, day: date.getDate(),
      hour: date.getHours(), minute: date.getMinutes(), second: date.getSeconds(), weekday: date.getDay() + 1,
    };
  }
  const parts: Record<string, string> = {};
  for (const part of formatter(timeZone).formatToParts(date)) parts[part.type] = part.value;
  return {
    year: Number(parts.year), month: Number(parts.month), day: Number(parts.day),
    hour: Number(parts.hour) % 24, minute: Number(parts.minute), second: Number(parts.second),
    weekday: weekdays.indexOf(parts.weekday) + 1,
  };
}

/** Le décalage UTC d'un fuseau à un instant, en millisecondes. */
function offsetAt(instant: number, timeZone: string): number {
  const w = wallTime(new Date(instant), timeZone);
  return Date.UTC(w.year, w.month - 1, w.day, w.hour, w.minute, w.second) - Math.floor(instant / 1000) * 1000;
}

/**
 * L'instant d'une heure murale dans un fuseau (le local quand il n'y en a pas). Les
 * jours et heures hors plage se reportent, comme `DateComponents` : « 31 + 1 jour ».
 */
export function fromWallTime(year: number, month: number, day: number, hour = 0, minute = 0, second = 0,
  timeZone: string | null = null): Date {
  if (timeZone === null) return new Date(year, month - 1, day, hour, minute, second);
  const asUTC = Date.UTC(year, month - 1, day, hour, minute, second);
  // Deux passes : le décalage se lit à l'instant visé, qui dépend lui-même du décalage
  // (changement d'heure).
  let guess = asUTC - offsetAt(asUTC, timeZone);
  guess = asUTC - offsetAt(guess, timeZone);
  return new Date(guess);
}

/** Une date décalée de `days` jours **calendaires** dans le fuseau, à la même heure murale. */
export function addCalendarDays(date: Date, days: number, timeZone: string | null = null): Date {
  const w = wallTime(date, timeZone);
  return fromWallTime(w.year, w.month, w.day + days, w.hour, w.minute, w.second, timeZone);
}

/** Minuit du jour de `date` dans le fuseau. */
export function startOfDayIn(date: Date, timeZone: string | null = null): Date {
  const w = wallTime(date, timeZone);
  return fromWallTime(w.year, w.month, w.day, 0, 0, 0, timeZone);
}
