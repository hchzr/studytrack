//! Le blocage d'étude (StudyLock du Mac) : StudyTrack occupe l'écran et garde le focus
//! (voir `kiosk.rs`). Rien n'est fermé, rien n'est écrit hors de l'app, aucun droit
//! administrateur : il n'y a donc rien à défaire après un plantage.

use std::sync::Mutex;

use serde::Serialize;

use super::kiosk;

#[derive(Default)]
pub struct LockState {
    inner: Mutex<Option<kiosk::Kiosk>>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Report {
    /// Le verrou existe sur ce système (Windows).
    pub supported: bool,
    /// L'écran est tenu en ce moment.
    pub active: bool,
    /// Les raccourcis système (Win, Alt+Tab…) sont avalés.
    pub keys_blocked: bool,
    /// Une phrase calme quand quelque chose n'est pas tenu.
    pub note: Option<String>,
}

fn release(app: &tauri::AppHandle, state: &LockState) {
    let mut guard = state.inner.lock().unwrap_or_else(|e| e.into_inner());
    if let Some(held) = guard.take() {
        kiosk::release(app, held);
    }
}

/// Prend l'écran (ou le reprend si déjà tenu).
#[tauri::command]
pub async fn study_lock_start(app: tauri::AppHandle, state: tauri::State<'_, LockState>) -> Result<Report, String> {
    release(&app, &state);
    let Some(held) = kiosk::engage(&app) else {
        return Ok(Report {
            supported: false,
            active: false,
            keys_blocked: false,
            note: Some("le verrou n'existe que dans l'app Windows".into()),
        });
    };
    let keys_blocked = held.keys_blocked;
    *state.inner.lock().unwrap_or_else(|e| e.into_inner()) = Some(held);
    Ok(Report {
        supported: true,
        active: true,
        keys_blocked,
        note: (!keys_blocked).then(|| "les raccourcis du système n'ont pas pu être bloqués".to_string()),
    })
}

#[tauri::command]
pub async fn study_lock_stop(app: tauri::AppHandle, state: tauri::State<'_, LockState>) -> Result<(), String> {
    release(&app, &state);
    Ok(())
}

/// À la sortie de l'app.
pub fn shutdown(app: &tauri::AppHandle, state: &LockState) {
    release(app, state);
}
