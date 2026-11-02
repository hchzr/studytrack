//! Blocage d'étude, au mieux (StudyLock du Mac) : apps fermées par un
//! scrutateur de processus, sites coupés par le fichier `hosts` si l'app en a
//! les droits. Tout est défait à la fin de la session **et** au lancement
//! (reprise après plantage). Les raccourcis système du Mac n'ont pas d'équivalent.

use std::sync::Mutex;

use serde::Serialize;

use super::{hosts, procwatch};

#[derive(Default)]
pub struct LockState {
    inner: Mutex<Active>,
}

#[derive(Default)]
struct Active {
    watcher: Option<procwatch::Watcher>,
    hosts_touched: bool,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Capabilities {
    /// Le blocage existe sur ce système (Windows).
    pub supported: bool,
    /// Le fichier `hosts` est écrivable (droits administrateur).
    pub can_block_sites: bool,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Report {
    pub supported: bool,
    pub watching: bool,
    pub sites_blocked: bool,
    /// Une phrase calme pour l'interface quand quelque chose n'est pas tenu.
    pub note: Option<String>,
}

pub const NEEDS_ADMIN: &str = "sites non bloqués (droits administrateur requis)";

/// Défait ce que le blocage a changé dans le système (au lancement, après un plantage).
pub fn recover() {
    if cfg!(target_os = "windows") {
        let _ = hosts::restore(&hosts::default_path());
    }
}

fn release(active: &mut Active) {
    if let Some(watcher) = active.watcher.take() {
        watcher.stop();
    }
    if active.hosts_touched {
        let _ = hosts::restore(&hosts::default_path());
        flush_dns();
        active.hosts_touched = false;
    }
}

#[cfg(target_os = "windows")]
fn flush_dns() {
    use std::os::windows::process::CommandExt;
    let _ = std::process::Command::new("ipconfig")
        .arg("/flushdns")
        .creation_flags(0x0800_0000)
        .status();
}

#[cfg(not(target_os = "windows"))]
fn flush_dns() {}

#[tauri::command]
pub fn study_lock_capabilities() -> Capabilities {
    let supported = cfg!(target_os = "windows");
    Capabilities { supported, can_block_sites: supported && hosts::writable(&hosts::default_path()) }
}

/// Démarre (ou renouvelle) le blocage : `apps` = exécutables à fermer, `sites` = domaines à couper.
#[tauri::command]
pub fn study_lock_start(state: tauri::State<'_, LockState>, apps: Vec<String>, sites: Vec<String>) -> Report {
    let mut active = state.inner.lock().unwrap_or_else(|e| e.into_inner());
    release(&mut active);
    if !cfg!(target_os = "windows") {
        return Report {
            supported: false,
            watching: false,
            sites_blocked: false,
            note: Some("blocage indisponible sur ce système".into()),
        };
    }
    let names: Vec<String> = apps.iter().filter_map(|a| procwatch::sanitize_exe(a)).collect();
    active.watcher = procwatch::start(names);

    let domains: Vec<String> = sites.iter().filter_map(|s| hosts::sanitize_domain(s)).collect();
    let mut sites_blocked = false;
    let mut note = None;
    if !domains.is_empty() {
        match hosts::apply(&hosts::default_path(), &domains) {
            hosts::Outcome::Blocked => {
                active.hosts_touched = true;
                sites_blocked = true;
                flush_dns();
            }
            hosts::Outcome::NeedsAdmin => note = Some(NEEDS_ADMIN.to_string()),
            hosts::Outcome::Failed(_) => note = Some("sites non bloqués (fichier hosts illisible)".to_string()),
        }
    }
    Report { supported: true, watching: active.watcher.is_some(), sites_blocked, note }
}

#[tauri::command]
pub fn study_lock_stop(state: tauri::State<'_, LockState>) {
    let mut active = state.inner.lock().unwrap_or_else(|e| e.into_inner());
    release(&mut active);
}

/// À la sortie de l'app : rien ne doit rester dans `hosts`.
pub fn shutdown(state: &LockState) {
    let mut active = state.inner.lock().unwrap_or_else(|e| e.into_inner());
    release(&mut active);
}
