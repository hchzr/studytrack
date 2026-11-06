//! Le verrou d'étude : pendant une session qui « bloque le reste », Polymestre **est** le
//! verrou (comme le mode étude du Mac qui prend l'écran). Fenêtre principale en plein écran,
//! toujours au-dessus, qui reprend le focus si une autre app le prend ; sous Windows, un
//! crochet clavier bas niveau avale Win, Alt+Tab, Alt+Échap, Ctrl+Échap, Alt+F4 et
//! Ctrl+Maj+Échap. Aucun droit administrateur, aucun processus fermé, aucun fichier touché.
//!
//! Zéro coût au repos : tout naît à `engage`, tout meurt à `release`, rien ne tourne entre
//! deux sessions. Ctrl+Alt+Suppr n'est pas interceptable : c'est la soupape du système.
//!
//! Reprise après plantage : rien à reprendre. Le crochet appartient au processus (il disparaît
//! avec lui) et on ne laisse aucune trace sur disque.

use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

use tauri::{AppHandle, Manager, WindowEvent};
#[cfg(target_os = "windows")]
use tauri::WebviewWindow;

#[cfg(target_os = "windows")]
#[path = "kiosk_win.rs"]
mod win;

/// Le verrou est-il tenu ? (Lu par le gestionnaire d'évènements de la fenêtre.)
static LOCKED: AtomicBool = AtomicBool::new(false);
static INSTALLED: AtomicBool = AtomicBool::new(false);

pub fn is_locked() -> bool {
    LOCKED.load(Ordering::SeqCst)
}

/// Faut-il avaler cette touche ? `vk` : code de touche virtuelle ; `alt`/`ctrl`/`shift` : modificateurs tenus.
/// Win (G/D), Alt+Tab, Alt+Échap, Ctrl+Échap (Démarrer), Ctrl+Maj+Échap (gestionnaire des tâches), Alt+F4.
#[cfg_attr(not(target_os = "windows"), allow(dead_code))]
pub fn decide(vk: u32, alt: bool, ctrl: bool, _shift: bool) -> bool {
    const TAB: u32 = 0x09;
    const ESCAPE: u32 = 0x1B;
    const F4: u32 = 0x73;
    const LWIN: u32 = 0x5B;
    const RWIN: u32 = 0x5C;
    match vk {
        LWIN | RWIN => true,
        TAB => alt,
        ESCAPE => alt || ctrl,
        F4 => alt,
        _ => false,
    }
}

/// Doit-on reprendre le focus ? Seulement si le verrou est tenu, que la principale ne l'a pas
/// et qu'aucune fenêtre **de l'app** (dialogue, connexion à un site) ne l'a.
pub fn should_refocus(locked: bool, main_focused: bool, own_window_focused: bool) -> bool {
    locked && !main_focused && !own_window_focused
}

/// Ce que `engage` a changé, pour le rendre à la fin.
pub struct Kiosk {
    #[cfg(target_os = "windows")]
    hook: Option<win::Hook>,
    changed_fullscreen: bool,
    prev_on_top: bool,
    /// Le crochet clavier est-il en place ? (Faux hors Windows, ou si le système l'a refusé.)
    pub keys_blocked: bool,
}

#[cfg(target_os = "windows")]
fn main_hwnd(window: &WebviewWindow) -> Option<isize> {
    window.hwnd().ok().map(|h| h.0 as isize)
}

fn own_window_focused(app: &AppHandle) -> bool {
    #[cfg(target_os = "windows")]
    if win::foreground_is_ours() {
        return true;
    }
    app.webview_windows().iter().any(|(label, w)| label != "main" && w.is_focused().unwrap_or(false))
}

fn refocus(app: &AppHandle) {
    let Some(window) = app.get_webview_window("main") else { return };
    let _ = window.unminimize();
    let _ = window.show();
    #[cfg(target_os = "windows")]
    if let Some(hwnd) = main_hwnd(&window) {
        win::bring_to_front(hwnd);
    }
    let _ = window.set_focus();
}

/// Branche, une fois, le gestionnaire de la fenêtre principale (il ne fait rien tant que le verrou n'est pas tenu).
pub fn install(app: &AppHandle) {
    if INSTALLED.swap(true, Ordering::SeqCst) {
        return;
    }
    let Some(window) = app.get_webview_window("main") else { return };
    let handle = app.clone();
    window.on_window_event(move |event| match event {
        // Le focus parti : on laisse un court instant au système pour donner le focus à une fenêtre
        // **de l'app** (dialogue, connexion), puis on reprend s'il est chez un étranger. Un seul
        // coup, déclenché par l'évènement — pas de scrutation.
        WindowEvent::Focused(false) if is_locked() => {
            let app = handle.clone();
            std::thread::spawn(move || {
                std::thread::sleep(Duration::from_millis(150));
                let main_focused = app
                    .get_webview_window("main")
                    .and_then(|w| w.is_focused().ok())
                    .unwrap_or(false);
                if should_refocus(is_locked(), main_focused, own_window_focused(&app)) {
                    refocus(&app);
                }
            });
        }
        // Pas de fermeture pendant le verrou (Alt+F4 est déjà avalé ; reste le bouton et le système).
        WindowEvent::CloseRequested { api, .. } if is_locked() => api.prevent_close(),
        _ => {}
    });
}

/// Prend l'écran. `None` hors Windows (le poste de développement n'est pas verrouillé).
pub fn engage(app: &AppHandle) -> Option<Kiosk> {
    if !cfg!(target_os = "windows") {
        return None;
    }
    let window = app.get_webview_window("main")?;
    install(app);
    // Le chrono flottant n'a rien à faire par-dessus le verrou.
    let _ = super::mini::set_visible(app, false);
    let was_fullscreen = window.is_fullscreen().unwrap_or(false);
    let prev_on_top = window.is_always_on_top().unwrap_or(false);
    let mut changed_fullscreen = false;
    if !was_fullscreen {
        changed_fullscreen = window.set_fullscreen(true).is_ok();
    }
    let _ = window.set_always_on_top(true);
    LOCKED.store(true, Ordering::SeqCst);
    refocus(app);

    #[cfg(target_os = "windows")]
    let hook = win::install();
    #[cfg(target_os = "windows")]
    let keys_blocked = hook.is_some();
    #[cfg(not(target_os = "windows"))]
    let keys_blocked = false;

    Some(Kiosk {
        #[cfg(target_os = "windows")]
        hook,
        changed_fullscreen,
        prev_on_top,
        keys_blocked,
    })
}

/// Rend l'écran : crochet retiré d'abord, puis la fenêtre comme elle était.
pub fn release(app: &AppHandle, kiosk: Kiosk) {
    LOCKED.store(false, Ordering::SeqCst);
    #[cfg(target_os = "windows")]
    if let Some(hook) = kiosk.hook {
        hook.stop();
    }
    if let Some(window) = app.get_webview_window("main") {
        let _ = window.set_always_on_top(kiosk.prev_on_top);
        if kiosk.changed_fullscreen {
            let _ = window.set_fullscreen(false);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const TAB: u32 = 0x09;
    const ESC: u32 = 0x1B;
    const F4: u32 = 0x73;

    #[test]
    fn swallows_the_ways_out() {
        assert!(decide(0x5B, false, false, false), "Win gauche");
        assert!(decide(0x5C, false, false, false), "Win droite");
        assert!(decide(0x5B, true, true, true), "Win avec modificateurs");
        assert!(decide(TAB, true, false, false), "Alt+Tab");
        assert!(decide(ESC, true, false, false), "Alt+Échap");
        assert!(decide(ESC, false, true, false), "Ctrl+Échap");
        assert!(decide(ESC, false, true, true), "Ctrl+Maj+Échap");
        assert!(decide(F4, true, false, false), "Alt+F4");
    }

    #[test]
    fn lets_ordinary_keys_through() {
        assert!(!decide(0x43, false, true, false), "Ctrl+C");
        assert!(!decide(0x56, false, true, false), "Ctrl+V");
        assert!(!decide(0x41, true, false, false), "Alt+A");
        assert!(!decide(0x45, true, true, true), "Ctrl+Alt+Maj+E");
        assert!(!decide(TAB, false, false, false), "Tab seul");
        assert!(!decide(TAB, false, true, false), "Ctrl+Tab");
        assert!(!decide(ESC, false, false, false), "Échap seul");
        assert!(!decide(ESC, false, false, true), "Maj+Échap");
        assert!(!decide(F4, false, false, false), "F4 seul");
        assert!(!decide(0x20, false, false, false), "Espace");
        assert!(!decide(0x11, false, false, false), "Ctrl seul");
        assert!(!decide(0x12, true, false, false), "Alt seul");
    }

    #[test]
    fn refocuses_only_for_foreign_windows() {
        assert!(should_refocus(true, false, false));
        assert!(!should_refocus(true, false, true), "dialogue ou connexion de l'app");
        assert!(!should_refocus(true, true, false), "déjà au premier plan");
        assert!(!should_refocus(false, false, false), "verrou levé");
    }
}
