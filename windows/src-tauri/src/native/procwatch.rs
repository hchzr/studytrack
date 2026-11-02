//! Surveillance des processus pendant un blocage : ferme les apps de la liste.
//!
//! Au mieux, assumé : un scrutateur de 2 s qui n'existe **que** pendant une
//! session verrouillée (le thread naît au début, meurt à la fin — rien au
//! repos). Un processus est d'abord prié de se fermer (`taskkill`, sans /F) ;
//! s'il est encore là deux battements plus tard, il est terminé.

use std::collections::{HashMap, HashSet};
use std::sync::mpsc;
use std::thread::JoinHandle;
use std::time::Duration;

pub const POLL: Duration = Duration::from_secs(2);

/// Jamais fermés, quoi que la liste dise : le système, l'explorateur, l'app elle-même et sa webview.
const PROTECTED: &[&str] = &[
    "explorer.exe", "studytrack.exe", "system", "svchost.exe", "csrss.exe", "winlogon.exe",
    "wininit.exe", "services.exe", "lsass.exe", "smss.exe", "dwm.exe", "taskmgr.exe",
    "msedgewebview2.exe", "cmd.exe", "powershell.exe", "conhost.exe", "sihost.exe",
    "fontdrvhost.exe", "ctfmon.exe", "searchhost.exe", "startmenuexperiencehost.exe",
    "shellexperiencehost.exe", "runtimebroker.exe", "taskhostw.exe",
];

/// Un nom d'exécutable sûr (`discord.exe`), en minuscules ; `None` s'il est suspect ou protégé.
pub fn sanitize_exe(entry: &str) -> Option<String> {
    let name = entry.trim().to_lowercase();
    let name = if name.ends_with(".exe") { name } else { format!("{name}.exe") };
    let valid = name.len() > 4
        && name.len() <= 64
        && name.chars().all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '-' | '_' | ' ' | '+'));
    (valid && !PROTECTED.contains(&name.as_str())).then_some(name)
}

#[derive(Debug, PartialEq, Eq, Clone, Copy)]
pub enum Action {
    /// Prier de fermer.
    Ask,
    /// Terminer.
    Force,
}

/// L'escalade : prier d'abord, terminer si le processus s'accroche.
#[derive(Default)]
pub struct Escalation {
    seen: HashMap<u32, u32>,
}

impl Escalation {
    /// Un battement : les processus de la liste vus maintenant → ce qu'on leur fait.
    pub fn step(&mut self, pids: &[u32]) -> Vec<(u32, Action)> {
        let alive: HashSet<u32> = pids.iter().copied().collect();
        self.seen.retain(|pid, _| alive.contains(pid));
        let mut actions = Vec::new();
        for pid in pids {
            let count = self.seen.entry(*pid).or_insert(0);
            *count += 1;
            match *count {
                1 => actions.push((*pid, Action::Ask)),
                0..=2 => {}
                _ => actions.push((*pid, Action::Force)),
            }
        }
        actions
    }
}

pub struct Watcher {
    stop: mpsc::Sender<()>,
    handle: Option<JoinHandle<()>>,
}

impl Watcher {
    pub fn stop(mut self) {
        let _ = self.stop.send(());
        if let Some(handle) = self.handle.take() {
            let _ = handle.join();
        }
    }
}

/// Lance le scrutateur ; `None` là où il n'existe pas (macOS de développement).
pub fn start(names: Vec<String>) -> Option<Watcher> {
    if !cfg!(target_os = "windows") || names.is_empty() {
        return None;
    }
    let wanted: HashSet<String> = names.into_iter().collect();
    let (tx, rx) = mpsc::channel::<()>();
    let handle = std::thread::Builder::new()
        .name("studytrack-procwatch".into())
        .spawn(move || {
            let mut escalation = Escalation::default();
            loop {
                let hits: Vec<u32> = sys::list()
                    .into_iter()
                    .filter(|(_, name)| wanted.contains(name))
                    .map(|(pid, _)| pid)
                    .collect();
                for (pid, action) in escalation.step(&hits) {
                    match action {
                        Action::Ask => sys::ask_close(pid),
                        Action::Force => sys::terminate(pid),
                    }
                }
                // Un message ou la fin du canal : on s'arrête ; le délai : battement suivant.
                if !matches!(rx.recv_timeout(POLL), Err(mpsc::RecvTimeoutError::Timeout)) {
                    break;
                }
            }
        })
        .ok()?;
    Some(Watcher { stop: tx, handle: Some(handle) })
}

#[cfg(target_os = "windows")]
mod sys {
    use std::os::windows::process::CommandExt;
    use windows_sys::Win32::Foundation::{CloseHandle, INVALID_HANDLE_VALUE};
    use windows_sys::Win32::System::Diagnostics::ToolHelp::{
        CreateToolhelp32Snapshot, Process32FirstW, Process32NextW, PROCESSENTRY32W, TH32CS_SNAPPROCESS,
    };
    use windows_sys::Win32::System::Threading::{OpenProcess, TerminateProcess, PROCESS_TERMINATE};

    const CREATE_NO_WINDOW: u32 = 0x0800_0000;

    /// (pid, nom en minuscules) de tous les processus.
    pub fn list() -> Vec<(u32, String)> {
        let mut out = Vec::new();
        // SAFETY: instantané du système ; l'entrée est initialisée avec sa taille avant l'appel,
        // la poignée est fermée à la sortie.
        unsafe {
            let snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
            if snapshot == INVALID_HANDLE_VALUE {
                return out;
            }
            let mut entry: PROCESSENTRY32W = std::mem::zeroed();
            entry.dwSize = std::mem::size_of::<PROCESSENTRY32W>() as u32;
            let mut ok = Process32FirstW(snapshot, &mut entry);
            while ok != 0 {
                let len = entry.szExeFile.iter().position(|&c| c == 0).unwrap_or(entry.szExeFile.len());
                let name = String::from_utf16_lossy(&entry.szExeFile[..len]).to_lowercase();
                out.push((entry.th32ProcessID, name));
                ok = Process32NextW(snapshot, &mut entry);
            }
            CloseHandle(snapshot);
        }
        out
    }

    /// Prie la fenêtre de se fermer (WM_CLOSE), sans /F.
    pub fn ask_close(pid: u32) {
        let _ = std::process::Command::new("taskkill")
            .args(["/PID", &pid.to_string()])
            .creation_flags(CREATE_NO_WINDOW)
            .status();
    }

    pub fn terminate(pid: u32) {
        // SAFETY: poignée ouverte puis fermée ici.
        unsafe {
            let handle = OpenProcess(PROCESS_TERMINATE, 0, pid);
            if !handle.is_null() {
                TerminateProcess(handle, 1);
                CloseHandle(handle);
            }
        }
    }
}

#[cfg(not(target_os = "windows"))]
mod sys {
    pub fn list() -> Vec<(u32, String)> {
        Vec::new()
    }
    pub fn ask_close(_pid: u32) {}
    pub fn terminate(_pid: u32) {}
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sanitizes_names() {
        assert_eq!(sanitize_exe("Discord"), Some("discord.exe".into()));
        assert_eq!(sanitize_exe(" Steam.EXE "), Some("steam.exe".into()));
        assert_eq!(sanitize_exe("explorer.exe"), None);
        assert_eq!(sanitize_exe("StudyTrack"), None);
        assert_eq!(sanitize_exe("..\\evil.exe"), None);
        assert_eq!(sanitize_exe("a/b"), None);
        assert_eq!(sanitize_exe(""), None);
    }

    #[test]
    fn escalates_ask_then_force() {
        let mut e = Escalation::default();
        assert_eq!(e.step(&[10]), vec![(10, Action::Ask)]);
        assert_eq!(e.step(&[10]), vec![]);
        assert_eq!(e.step(&[10]), vec![(10, Action::Force)]);
        // Parti puis revenu : on recommence poliment.
        assert_eq!(e.step(&[]), vec![]);
        assert_eq!(e.step(&[10]), vec![(10, Action::Ask)]);
    }
}
