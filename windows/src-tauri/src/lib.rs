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
        // Choisir un PDF (boîte de dialogue du système) et garder celui d'une série.
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_fs::init())
        // Réseau côté Rust : les fonctions Supabase et les sites de cours n'envoient pas d'en-têtes CORS.
        .plugin(tauri_plugin_http::init())
        .manage(native::lock::LockState::default())
        .manage(native::site::SiteState::default())
        .manage(native::oauth::OAuthState::default())
        .invoke_handler(tauri::generate_handler![
            greet,
            native::power::set_keep_awake,
            native::lock::study_lock_start,
            native::lock::study_lock_stop,
            native::mini::mini_set_visible,
            native::oauth::oauth_start,
            native::oauth::oauth_cancel,
            native::site::site_login_open,
            native::site::site_login_close,
            native::site::web_open,
            native::ed::ed_sign_in,
            native::ed::ed_sign_out,
            native::site::site_request,
            native::site::site_download,
            native::site::site_cookie,
            native::secrets::secrets_load,
            native::secrets::secret_set,
        ])
        .setup(|app| {
            // Les sites où l'on s'est déjà connecté (les cookies, eux, sont dans WebView2).
            app.state::<native::site::SiteState>().load(app.handle());
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
                native::lock::shutdown(app, &app.state::<native::lock::LockState>());
                native::power::set(native::power::Hold::Off, 60);
            }
        });
}
