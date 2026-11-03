// Les icônes de l'app : les noms SF Symbols du Swift, dessinés par lucide.
// Un port écrit `<Icon name="calendar" />` là où le Swift avait
// `Image(systemName: "calendar")` — jamais d'émoji ni de caractère dessin.
// Un nom manquant : l'ajouter ici (une ligne), pas ailleurs.

import type { CSSProperties } from "react";
import {
  AlarmClock, AlertTriangle, ArrowLeft, ArrowRight, ArrowUpRight, BarChart3, Bell, BookOpen, Bookmark,
  Calculator, Calendar, CalendarClock, Check, CheckCircle2, CheckSquare, ChevronDown, ChevronLeft,
  ChevronRight, ChevronUp, Circle, Clock, Cloud, CloudOff, Coffee, Copy, Download, Ellipsis,
  ExternalLink, Eye, EyeOff, FileText, Flag, Folder, GraduationCap, Hourglass, Inbox, Info, Library,
  Link, List, Lock, LockOpen, LogOut, Moon, Music, NotebookPen, Pause, Pencil, Play, Plus, Quote,
  RefreshCw, RotateCcw, Search, Settings, Share, Sidebar, SkipForward, Smile, Sparkles, Square,
  Star, Sun, Target, Timer, Trash2, Upload, User, Users, X, XCircle, Zap, Heart, Layers, Map,
  Repeat, Volume2, VolumeX, Wifi, Battery, Maximize2, Minimize2, PanelRight, Brain, Lightbulb,
  Landmark, ListOrdered, GalleryVerticalEnd, BadgeCheck, MoonStar, FastForward, PictureInPicture2,
  ListChecks, MonitorPlay, Minus, Equal, CircleHelp, ClipboardPaste, FilePlus, FileSearch, ScanSearch,
  SquareDashed, StarOff, CopyPlus, IndentIncrease, IndentDecrease, AlignLeft, ListPlus, CirclePlus, FileScan,
  Shuffle, Repeat1, SkipBack, Volume1, ListMusic, Laptop, Smartphone, Tablet, Speaker, Tv, ChevronsUpDown,
  type LucideIcon,
} from "lucide-react";

const ICONS = {
  // Navigation et pages
  "sun.max": Sun, "timer": Timer, "calendar": Calendar, "chart.bar.xaxis": BarChart3, "sparkle": Sparkles,
  "sparkles": Sparkles, "books.vertical": Library, "book": BookOpen, "gearshape": Settings,
  "magnifyingglass": Search, "sidebar.left": Sidebar, "sidebar.right": PanelRight,
  "graduationcap": GraduationCap, "person": User, "person.2": Users, "map": Map, "brain": Brain,
  // Actions
  "plus": Plus, "xmark": X, "checkmark": Check, "pencil": Pencil, "trash": Trash2, "doc.on.doc": Copy,
  "square.and.arrow.up": Share, "square.and.arrow.down": Download, "arrow.up.doc": Upload,
  "arrow.clockwise": RefreshCw, "arrow.counterclockwise": RotateCcw, "repeat": Repeat,
  "arrow.left": ArrowLeft, "arrow.right": ArrowRight, "arrow.up.right": ArrowUpRight,
  "arrow.up.right.square": ExternalLink, "link": Link, "ellipsis": Ellipsis,
  "chevron.left": ChevronLeft, "chevron.right": ChevronRight, "chevron.up": ChevronUp, "chevron.down": ChevronDown,
  "rectangle.portrait.and.arrow.right": LogOut, "arrow.up.left.and.arrow.down.right": Maximize2,
  "arrow.down.right.and.arrow.up.left": Minimize2,
  // Chrono et étude
  "play.fill": Play, "pause.fill": Pause, "stop.fill": Square, "forward.end.fill": SkipForward,
  "clock": Clock, "alarm": AlarmClock, "hourglass": Hourglass, "cup.and.saucer": Coffee,
  "moon": Moon, "lock": Lock, "lock.open": LockOpen, "target": Target, "bolt": Zap, "calendar.badge.clock": CalendarClock,
  "music.note": Music, "shuffle": Shuffle, "repeat.1": Repeat1, "backward.fill": SkipBack, "speaker.fill": Volume1,
  "speaker.wave.3.fill": Volume2, "music.note.list": ListMusic, "laptopcomputer": Laptop, "iphone": Smartphone, "ipad": Tablet,
  "hifispeaker": Speaker, "tv": Tv, "chevron.up.chevron.down": ChevronsUpDown, "speaker.wave.2": Volume2, "speaker.slash": VolumeX, "wifi": Wifi, "battery.75": Battery,
  "face.smiling": Smile, "heart": Heart, "lightbulb": Lightbulb, "square.stack.3d.up": Layers,
  // Contenu
  "doc.text": FileText, "folder": Folder, "tray": Inbox, "list.bullet": List, "note.text": NotebookPen,
  "quote.opening": Quote, "bookmark": Bookmark, "star": Star, "flag": Flag, "function": Calculator,
  "checkmark.circle": CheckCircle2, "checkmark.square": CheckSquare, "circle": Circle, "xmark.circle": XCircle,
  "exclamationmark.triangle": AlertTriangle, "info.circle": Info, "bell": Bell,
  "eye": Eye, "eye.slash": EyeOff, "icloud": Cloud, "icloud.slash": CloudOff,
  // Noms remontés par les ports (variantes .fill : même dessin au trait).
  "building.columns": Landmark, "list.number": ListOrdered, "rectangle.stack": GalleryVerticalEnd,
  "checkmark.seal": BadgeCheck, "moon.stars": MoonStar, "moon.stars.fill": MoonStar, "person.2.fill": Users,
  "forward.fill": FastForward, "pip": PictureInPicture2, "books.vertical.fill": Library, "checklist": ListChecks,
  "play.rectangle.fill": MonitorPlay, "graduationcap.fill": GraduationCap, "minus": Minus, "equal": Equal,
  "questionmark": CircleHelp,
  // Import d'une série (PDF).
  "doc.badge.plus": FilePlus, "doc.on.clipboard": ClipboardPaste, "doc.text.magnifyingglass": FileSearch,
  "text.magnifyingglass": ScanSearch, "rectangle.dashed": SquareDashed, "star.slash": StarOff, "star.fill": Star,
  "plus.rectangle.on.rectangle": CopyPlus, "increase.indent": IndentIncrease, "decrease.indent": IndentDecrease,
  "text.alignleft": AlignLeft, "text.badge.plus": ListPlus, "plus.circle.fill": CirclePlus,
  "doc.viewfinder": FileScan, "checkmark.circle.fill": CheckCircle2, "exclamationmark.triangle.fill": AlertTriangle,
  "checkmark.seal.fill": BadgeCheck,
} satisfies Record<string, LucideIcon>;

export type IconName = keyof typeof ICONS;

/** Une icône au trait fin, de la couleur du texte autour (ou `color`). */
export function Icon({ name, size = 16, strokeWidth = 1.75, color, style, className, label }: {
  name: IconName; size?: number; strokeWidth?: number; color?: string;
  style?: CSSProperties; className?: string;
  /** Pour une icône seule porteuse de sens ; sinon elle est décorative. */
  label?: string;
}) {
  // Un nom inconnu (une icône du Mac sans équivalent) : un rond, plutôt qu'un écran cassé.
  const Glyph = ICONS[name] ?? ICONS["circle"];
  return (
    <Glyph size={size} strokeWidth={strokeWidth} color={color} style={style} className={className}
      aria-hidden={label ? undefined : true} aria-label={label} role={label ? "img" : undefined} />
  );
}
