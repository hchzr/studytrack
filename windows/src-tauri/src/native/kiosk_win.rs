//! La partie Win32 du verrou : le crochet clavier bas niveau et la mise au premier plan.
//! Aucune dépendance à Tauri (les fenêtres sont passées en `isize`), pour pouvoir être
//! vérifiée seule contre `windows-sys`.

use std::ptr::{null, null_mut};
use std::sync::mpsc;
use std::thread::JoinHandle;
use std::time::Duration;

use windows_sys::Win32::Foundation::{LPARAM, LRESULT, WPARAM};
use windows_sys::Win32::System::LibraryLoader::GetModuleHandleW;
use windows_sys::Win32::System::Threading::{AttachThreadInput, GetCurrentProcessId, GetCurrentThreadId};
use windows_sys::Win32::UI::Input::KeyboardAndMouse::GetAsyncKeyState;
use windows_sys::Win32::UI::WindowsAndMessaging::{
    BringWindowToTop, CallNextHookEx, GetForegroundWindow, GetMessageW, GetWindowThreadProcessId, PeekMessageW,
    PostThreadMessageW, SetForegroundWindow, SetWindowsHookExW, UnhookWindowsHookEx, KBDLLHOOKSTRUCT, MSG,
    PM_NOREMOVE, WH_KEYBOARD_LL, WM_QUIT,
};

use super::decide;

const HC_ACTION: i32 = 0;
const LLKHF_ALTDOWN: u32 = 0x20;
const VK_SHIFT: i32 = 0x10;
const VK_CONTROL: i32 = 0x11;

fn held(vk: i32) -> bool {
    // SAFETY: lecture de l'état d'une touche, sans effet de bord.
    unsafe { GetAsyncKeyState(vk) < 0 }
}

/// Appelé par le système pour chaque touche, sur le fil du crochet. Rendre 1 l'avale.
unsafe extern "system" fn hook_proc(code: i32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
    if code == HC_ACTION {
        // SAFETY: pour WH_KEYBOARD_LL, `lparam` pointe un KBDLLHOOKSTRUCT valide pendant l'appel.
        let info = unsafe { &*(lparam as *const KBDLLHOOKSTRUCT) };
        let alt = info.flags & LLKHF_ALTDOWN != 0;
        if decide(info.vkCode, alt, held(VK_CONTROL), held(VK_SHIFT)) {
            return 1;
        }
    }
    // SAFETY: on transmet tel quel au crochet suivant (le premier argument est ignoré).
    unsafe { CallNextHookEx(null_mut(), code, wparam, lparam) }
}

/// Le crochet et le fil qui le porte (il faut une boucle de messages sur ce fil).
pub struct Hook {
    thread_id: u32,
    handle: Option<JoinHandle<()>>,
}

impl Hook {
    /// Retire le crochet : `WM_QUIT` au fil, qui se désabonne en sortant, puis on l'attend.
    pub fn stop(mut self) {
        // SAFETY: simple envoi de message au fil du crochet.
        unsafe { PostThreadMessageW(self.thread_id, WM_QUIT, 0, 0) };
        if let Some(handle) = self.handle.take() {
            let _ = handle.join();
        }
    }
}

/// Installe le crochet ; `None` si le système le refuse.
pub fn install() -> Option<Hook> {
    let (tx, rx) = mpsc::channel::<Option<u32>>();
    let handle = std::thread::Builder::new()
        .name("polymestre-kiosk-hook".into())
        .spawn(move || {
            // SAFETY: tout reste sur ce fil ; le crochet est retiré avant de sortir.
            unsafe {
                let hook = SetWindowsHookExW(WH_KEYBOARD_LL, Some(hook_proc), GetModuleHandleW(null()), 0);
                if hook.is_null() {
                    let _ = tx.send(None);
                    return;
                }
                let mut msg: MSG = std::mem::zeroed();
                // Crée la file de messages du fil avant d'annoncer son identifiant (WM_QUIT en dépend).
                PeekMessageW(&mut msg, null_mut(), 0, 0, PM_NOREMOVE);
                let _ = tx.send(Some(GetCurrentThreadId()));
                // Le système appelle `hook_proc` depuis GetMessageW ; WM_QUIT rend 0.
                while GetMessageW(&mut msg, null_mut(), 0, 0) > 0 {}
                UnhookWindowsHookEx(hook);
            }
        })
        .ok()?;
    match rx.recv_timeout(Duration::from_secs(2)) {
        Ok(Some(thread_id)) => Some(Hook { thread_id, handle: Some(handle) }),
        _ => None,
    }
}

/// La fenêtre au premier plan est-elle une fenêtre de ce processus ?
pub fn foreground_is_ours() -> bool {
    // SAFETY: lectures seules.
    unsafe {
        let foreground = GetForegroundWindow();
        if foreground.is_null() {
            return false;
        }
        let mut pid = 0u32;
        GetWindowThreadProcessId(foreground, &mut pid);
        pid == GetCurrentProcessId()
    }
}

/// Ramène `hwnd` au premier plan. `SetForegroundWindow` est refusé à un processus qui n'a pas
/// le focus ; rattacher l'entrée de notre fil à celle du fil au premier plan le temps de
/// l'appel lève cette restriction (technique usuelle, sans droits particuliers).
pub fn bring_to_front(hwnd: isize) {
    let target = hwnd as *mut std::ffi::c_void;
    // SAFETY: appels Win32 sur des identifiants valides ; l'attache est toujours défaite.
    unsafe {
        let foreground = GetForegroundWindow();
        let foreground_thread = if foreground.is_null() { 0 } else { GetWindowThreadProcessId(foreground, null_mut()) };
        let ours = GetCurrentThreadId();
        let attached = foreground_thread != 0 && foreground_thread != ours && AttachThreadInput(ours, foreground_thread, 1) != 0;
        BringWindowToTop(target);
        SetForegroundWindow(target);
        if attached {
            AttachThreadInput(ours, foreground_thread, 0);
        }
    }
}
