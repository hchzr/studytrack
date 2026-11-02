//! Garder la machine éveillée pendant une session (équivalent de MacKeepAwake).
//!
//! `SetThreadExecutionState` vaut **pour le thread appelant** : on le tient donc
//! depuis un thread dédié qui dort sur un canal (zéro coût au repos). Le bail
//! (`lease`) est l'échéance : si le JS ne renouvelle pas (plantage, webview
//! figée), le thread relâche seul — la machine finit par dormir.

use std::sync::{mpsc, Mutex, OnceLock};
use std::time::Duration;

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Hold {
    Off,
    System,
    Display,
}

impl Hold {
    pub fn parse(text: &str) -> Option<Hold> {
        match text {
            "off" => Some(Hold::Off),
            "system" => Some(Hold::System),
            "display" => Some(Hold::Display),
            _ => None,
        }
    }
}

/// Un bail trop court ferait relâcher aussitôt : plancher d'une minute, plafond de 12 h.
pub fn clamp_lease(seconds: u64) -> Duration {
    Duration::from_secs(seconds.clamp(60, 12 * 3600))
}

enum Msg {
    Set(Hold, Duration),
}

static WORKER: OnceLock<Mutex<mpsc::Sender<Msg>>> = OnceLock::new();

fn sender() -> &'static Mutex<mpsc::Sender<Msg>> {
    WORKER.get_or_init(|| {
        let (tx, rx) = mpsc::channel();
        std::thread::Builder::new()
            .name("studytrack-keep-awake".into())
            .spawn(move || worker(rx))
            .expect("thread keep-awake");
        Mutex::new(tx)
    })
}

fn worker(rx: mpsc::Receiver<Msg>) {
    let mut lease: Option<Duration> = None;
    loop {
        let received = match lease {
            Some(duration) => rx.recv_timeout(duration),
            None => rx.recv().map_err(|_| mpsc::RecvTimeoutError::Disconnected),
        };
        match received {
            Ok(Msg::Set(hold, duration)) => {
                apply(hold);
                lease = if hold == Hold::Off { None } else { Some(duration) };
            }
            Err(mpsc::RecvTimeoutError::Timeout) => {
                apply(Hold::Off);
                lease = None;
            }
            Err(mpsc::RecvTimeoutError::Disconnected) => {
                apply(Hold::Off);
                break;
            }
        }
    }
}

#[cfg(target_os = "windows")]
fn apply(hold: Hold) {
    use windows_sys::Win32::System::Power::{
        SetThreadExecutionState, ES_CONTINUOUS, ES_DISPLAY_REQUIRED, ES_SYSTEM_REQUIRED,
    };
    let flags = match hold {
        Hold::Off => ES_CONTINUOUS,
        Hold::System => ES_CONTINUOUS | ES_SYSTEM_REQUIRED,
        Hold::Display => ES_CONTINUOUS | ES_SYSTEM_REQUIRED | ES_DISPLAY_REQUIRED,
    };
    // SAFETY: appel sans pointeur ; l'état vaut pour ce thread, qui vit tant que l'app.
    unsafe {
        SetThreadExecutionState(flags);
    }
}

/// Sur macOS (poste de développement) : rien à tenir.
#[cfg(not(target_os = "windows"))]
fn apply(_hold: Hold) {}

pub fn set(hold: Hold, lease_seconds: u64) {
    // Rien à relâcher et jamais rien tenu : ne pas même créer le thread.
    if hold == Hold::Off && WORKER.get().is_none() {
        return;
    }
    if let Ok(tx) = sender().lock() {
        let _ = tx.send(Msg::Set(hold, clamp_lease(lease_seconds)));
    }
}

/// `off` | `system` | `display`, avec le bail en secondes.
#[tauri::command]
pub fn set_keep_awake(mode: String, lease_seconds: u64) -> Result<(), String> {
    let hold = Hold::parse(&mode).ok_or_else(|| format!("mode inconnu : {mode}"))?;
    set(hold, lease_seconds);
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_modes() {
        assert_eq!(Hold::parse("display"), Some(Hold::Display));
        assert_eq!(Hold::parse("nope"), None);
    }

    #[test]
    fn lease_is_clamped() {
        assert_eq!(clamp_lease(5), Duration::from_secs(60));
        assert_eq!(clamp_lease(7200), Duration::from_secs(7200));
        assert_eq!(clamp_lease(10_000_000), Duration::from_secs(43_200));
    }
}
