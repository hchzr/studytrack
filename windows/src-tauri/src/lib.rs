// Learn more about Tauri commands at https://tauri.app/develop/calling-rust/
mod native;

use tauri::{
    menu::{Menu, MenuItem},
    tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent},
    Emitter, Manager,
};

#[tauri::command]
fn greet(name: &str) -> String {
    format!("Hello, {}! You've been greeted from Rust!", name)
}

/// Amène la fenêtre principale devant (menu du plateau, clic du plateau,
/// raccourci global côté webview).
fn show_main(app: &tauri::AppHandle) {
    if let Some(window) = app.get_webview_window("main") {
        let _ = window.show();
        let _ = window.unminimize();
        let _ = window.set_focus();
    }
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_opener::init())
        // SQLite de l'app, ouverte depuis la webview (`Database.load`).
        .plugin(tauri_plugin_sql::Builder::default().build())
        // Le raccourci global (⌃⌥Espace) s'enregistre côté webview.
        .plugin(tauri_plugin_global_shortcut::Builder::new().build())
        .manage(native::lock::LockState::default())
        .invoke_handler(tauri::generate_handler![
            greet,
            native::power::set_keep_awake,
            native::lock::study_lock_capabilities,
            native::lock::study_lock_start,
            native::lock::study_lock_stop,
            native::mini::mini_set_visible,
        ])
        .setup(|app| {
            // Reprise après plantage : rien du blocage ne doit rester dans `hosts`.
            native::lock::recover();
            // Le plateau (zone de notification) : l'icône de l'app, ouvrir, quitter.
            let open = MenuItem::with_id(app, "open", "Ouvrir StudyTrack", true, None::<&str>)?;
            let mini = MenuItem::with_id(app, "mini", "Mini chrono", true, None::<&str>)?;
            let quit = MenuItem::with_id(app, "quit", "Quitter StudyTrack", true, None::<&str>)?;
            let menu = Menu::with_items(app, &[&open, &mini, &quit])?;
            TrayIconBuilder::with_id("main")
                .icon(app.default_window_icon().expect("icône de l'app").clone())
                .tooltip("StudyTrack")
                .menu(&menu)
                .show_menu_on_left_click(false)
                .on_menu_event(|app, event| match event.id.as_ref() {
                    "open" => show_main(app),
                    // Le réglage vit côté webview : la fenêtre principale bascule et ré-évalue.
                    "mini" => {
                        let _ = app.emit("mini:toggle", ());
                    }
                    "quit" => app.exit(0),
                    _ => {}
                })
                .on_tray_icon_event(|tray, event| {
                    // Un clic gauche ouvre la fenêtre, comme l'app du Mac.
                    if let TrayIconEvent::Click {
                        button: MouseButton::Left,
                        button_state: MouseButtonState::Up,
                        ..
                    } = event
                    {
                        show_main(tray.app_handle());
                    }
                })
                .build(app)?;
            Ok(())
        })
        .build(tauri::generate_context!())
        .expect("error while building tauri application")
        .run(|app, event| {
            if let tauri::RunEvent::Exit = event {
                native::mini::persist(app);
                native::lock::shutdown(&app.state::<native::lock::LockState>());
                native::power::set(native::power::Hold::Off, 60);
            }
        });
}
