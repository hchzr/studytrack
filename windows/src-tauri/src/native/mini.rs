//! Le chrono flottant (MiniTimerPanel du Mac) : une petite fenêtre sans cadre,
//! toujours au-dessus, hors barre des tâches, qui retient sa place.
//!
//! Créée à la demande (rien n'existe tant qu'aucune session ne tourne) et
//! cachée — pas détruite — ensuite. L'état du chrono lui vient de la fenêtre
//! principale par événements (voir src/native/miniBridge.ts).

use std::path::PathBuf;
use std::sync::Mutex;

use serde::{Deserialize, Serialize};
use tauri::{
    AppHandle, Manager, PhysicalPosition, WebviewUrl, WebviewWindow, WebviewWindowBuilder, WindowEvent,
};

pub const LABEL: &str = "mini";
/// Pilule 236 × 52 plus 8 px de marge pour l'ombre.
const WIDTH: f64 = 252.0;
const HEIGHT: f64 = 68.0;
const MARGIN: f64 = 24.0;

#[derive(Serialize, Deserialize, Clone, Copy, PartialEq, Debug)]
pub struct Spot {
    pub x: i32,
    pub y: i32,
}

/// La dernière place connue ; écrite sur disque à la fermeture et au masquage.
static LAST: Mutex<Option<Spot>> = Mutex::new(None);

fn spot_file(app: &AppHandle) -> Option<PathBuf> {
    app.path().app_data_dir().ok().map(|dir| dir.join("mini-position.json"))
}

fn load_spot(app: &AppHandle) -> Option<Spot> {
    let text = std::fs::read_to_string(spot_file(app)?).ok()?;
    serde_json::from_str(&text).ok()
}

pub fn persist(app: &AppHandle) {
    let Some(spot) = LAST.lock().ok().and_then(|g| *g) else { return };
    let Some(file) = spot_file(app) else { return };
    if let Some(dir) = file.parent() {
        let _ = std::fs::create_dir_all(dir);
    }
    if let Ok(text) = serde_json::to_string(&spot) {
        let _ = std::fs::write(file, text);
    }
}

/// Le point `(x, y)` est-il dans l'un des écrans ? (Un écran débranché : retour au coin par défaut.)
pub fn inside_any(spot: Spot, rects: &[(i32, i32, i32, i32)]) -> bool {
    rects.iter().any(|&(left, top, width, height)| {
        spot.x >= left - 40 && spot.y >= top - 10 && spot.x < left + width - 40 && spot.y < top + height - 20
    })
}

fn default_spot(window: &WebviewWindow) -> Option<Spot> {
    let monitor = window.primary_monitor().ok().flatten().or_else(|| window.current_monitor().ok().flatten())?;
    let scale = monitor.scale_factor();
    let position = monitor.position();
    let size = monitor.size();
    Some(Spot {
        x: position.x + size.width as i32 - ((WIDTH + MARGIN) * scale) as i32,
        y: position.y + (MARGIN * scale) as i32,
    })
}

fn ensure(app: &AppHandle) -> tauri::Result<WebviewWindow> {
    if let Some(window) = app.get_webview_window(LABEL) {
        return Ok(window);
    }
    let builder = WebviewWindowBuilder::new(app, LABEL, WebviewUrl::App("index.html?window=mini".into()))
        .title("Chrono StudyTrack")
        .inner_size(WIDTH, HEIGHT)
        .decorations(false)
        .resizable(false)
        .maximizable(false)
        .minimizable(false)
        .always_on_top(true)
        .skip_taskbar(true)
        .shadow(false)
        .focusable(false)
        .visible(false);
    // La transparence sur macOS demande l'API privée : on ne la prend que sous Windows.
    #[cfg(target_os = "windows")]
    let builder = builder.transparent(true);
    let window = builder.build()?;

    let rects: Vec<(i32, i32, i32, i32)> = window
        .available_monitors()
        .unwrap_or_default()
        .iter()
        .map(|m| (m.position().x, m.position().y, m.size().width as i32, m.size().height as i32))
        .collect();
    let spot = load_spot(app).filter(|s| inside_any(*s, &rects)).or_else(|| default_spot(&window));
    if let Some(spot) = spot {
        let _ = window.set_position(PhysicalPosition::new(spot.x, spot.y));
        if let Ok(mut last) = LAST.lock() {
            *last = Some(spot);
        }
    }
    let handle = app.clone();
    window.on_window_event(move |event| match event {
        WindowEvent::Moved(position) => {
            if let Ok(mut last) = LAST.lock() {
                *last = Some(Spot { x: position.x, y: position.y });
            }
        }
        WindowEvent::Destroyed => persist(&handle),
        _ => {}
    });
    Ok(window)
}

pub fn set_visible(app: &AppHandle, visible: bool) -> Result<(), String> {
    if visible {
        let window = ensure(app).map_err(|e| e.to_string())?;
        if !window.is_visible().unwrap_or(false) {
            window.show().map_err(|e| e.to_string())?;
        }
    } else if let Some(window) = app.get_webview_window(LABEL) {
        if window.is_visible().unwrap_or(false) {
            persist(app);
            window.hide().map_err(|e| e.to_string())?;
        }
    }
    Ok(())
}

#[tauri::command]
pub fn mini_set_visible(app: AppHandle, visible: bool) -> Result<(), String> {
    set_visible(&app, visible)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn spot_must_be_on_a_screen() {
        let screens = [(0, 0, 1920, 1080)];
        assert!(inside_any(Spot { x: 1600, y: 24 }, &screens));
        assert!(!inside_any(Spot { x: 4000, y: 24 }, &screens));
        assert!(!inside_any(Spot { x: 100, y: 5000 }, &screens));
    }
}
