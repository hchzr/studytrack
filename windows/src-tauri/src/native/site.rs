//! Les sites de cours (Moodle, Courseware, Ed…) : une fenêtre de connexion, et des
//! requêtes faites **avec la session** de cette fenêtre.
//!
//! Le Mac lit ces sites dans un navigateur invisible (`HiddenSiteSession`) et y
//! exécute leurs propres appels. Une page distante n'a pas le droit d'appeler les
//! commandes de l'app, et un `fetch` de la webview principale bute sur CORS : on
//! fait donc les requêtes ici, en Rust, avec les cookies que WebView2 a reçus de la
//! fenêtre de connexion (`cookies_for_url`, cookies HttpOnly compris — c'est ce qui
//! porte `MoodleSession`). L'identité est celle de l'étudiant·e, comme dans son
//! navigateur ; rien n'est stocké hors de WebView2.
//!
//! Sécurité : seules les requêtes `https` vers un domaine **déclaré par une fenêtre
//! de connexion** partent (le domaine de l'école, pas tout Internet), et rien ne
//! traverse la webview que le texte rendu.

use std::collections::HashSet;
use std::sync::Mutex;
use std::time::Duration;

use serde::{Deserialize, Serialize};
use tauri::{AppHandle, Manager, State, Url, WebviewUrl, WebviewWindowBuilder};
use tauri_plugin_http::reqwest;

/// Les domaines (« epfl.ch ») dont une fenêtre de connexion a été ouverte.
/// Retenus d'un lancement à l'autre (`site-domains.json`, noms de domaine seulement — les
/// cookies restent dans WebView2) : sans cela, chaque relance redemandait d'ouvrir la connexion.
#[derive(Default)]
pub struct SiteState {
    domains: Mutex<HashSet<String>>,
}

const DOMAINS_FILE: &str = "site-domains.json";

impl SiteState {
    /// Relit les domaines déjà déclarés (au démarrage).
    pub fn load(&self, app: &AppHandle) {
        let Ok(dir) = app.path().app_config_dir() else { return };
        let Ok(text) = std::fs::read_to_string(dir.join(DOMAINS_FILE)) else { return };
        let saved: Vec<String> = serde_json::from_str(&text).unwrap_or_default();
        if let Ok(mut domains) = self.domains.lock() {
            domains.extend(saved.into_iter().filter(|d| is_domain(d)));
        }
    }

    fn remember(&self, app: &AppHandle, domain: String) {
        let Ok(mut domains) = self.domains.lock() else { return };
        if !domains.insert(domain) {
            return;
        }
        let mut list: Vec<&String> = domains.iter().collect();
        list.sort();
        if let (Ok(dir), Ok(json)) = (app.path().app_config_dir(), serde_json::to_string(&list)) {
            let _ = std::fs::create_dir_all(&dir);
            let _ = std::fs::write(dir.join(DOMAINS_FILE), json);
        }
    }
}

/// Un nom de domaine plausible (le fichier peut avoir été modifié à la main).
fn is_domain(s: &str) -> bool {
    !s.is_empty() && s.len() <= 253 && s.contains('.') && s.chars().all(|c| c.is_ascii_alphanumeric() || c == '.' || c == '-')
}

/// Le domaine d'enregistrement d'un hôte : ses deux derniers segments (« moodle.epfl.ch » → « epfl.ch »).
fn base_domain(host: &str) -> String {
    let parts: Vec<&str> = host.split('.').collect();
    if parts.len() <= 2 {
        host.to_string()
    } else {
        parts[parts.len() - 2..].join(".")
    }
}

fn allowed(state: &SiteState, url: &Url) -> bool {
    if url.scheme() != "https" {
        return false;
    }
    let Some(host) = url.host_str() else { return false };
    state.domains.lock().map(|d| d.contains(&base_domain(host))).unwrap_or(false)
}

/// Ouvre la fenêtre de connexion d'un site (une seule par site), et en retient le domaine.
///
/// `async` est obligatoire : créer une fenêtre depuis une commande synchrone (qui tourne sur
/// le fil principal) bloque la boucle de messages sous Windows (tauri-apps/tauri#4121,
/// wry#583) — le bouton « ne faisait rien ».
#[tauri::command]
pub async fn site_login_open(app: AppHandle, state: State<'_, SiteState>, label: String, url: String, title: String) -> Result<(), String> {
    let parsed = Url::parse(&url).map_err(|e| e.to_string())?;
    if parsed.scheme() != "https" {
        return Err("Seules les adresses https sont acceptées.".into());
    }
    let host = parsed.host_str().ok_or("Adresse sans hôte.")?.to_string();
    state.remember(&app, base_domain(&host));
    let label = format!("site-{label}");
    if let Some(window) = app.get_webview_window(&label) {
        let _ = window.navigate(parsed);
        let _ = window.show();
        // Sous le verrou d'étude la principale est « toujours au-dessus » : la connexion doit l'être aussi.
        let _ = window.set_always_on_top(super::kiosk::is_locked());
        let _ = window.set_focus();
        return Ok(());
    }
    WebviewWindowBuilder::new(&app, &label, WebviewUrl::External(parsed))
        .title(title)
        .inner_size(980.0, 760.0)
        .always_on_top(super::kiosk::is_locked())
        .build()
        .map_err(|e| e.to_string())?;
    Ok(())
}

/// Ferme la fenêtre de connexion d'un site (la session reste dans WebView2).
#[tauri::command]
pub async fn site_login_close(app: AppHandle, label: String) {
    if let Some(window) = app.get_webview_window(&format!("site-{label}")) {
        let _ = window.close();
    }
}

#[derive(Deserialize)]
pub struct SiteRequest {
    pub url: String,
    pub method: Option<String>,
    pub headers: Option<Vec<(String, String)>>,
    pub body: Option<String>,
    /// Secondes avant d'abandonner (20 par défaut).
    pub timeout: Option<u64>,
}

#[derive(Serialize)]
pub struct SiteResponse {
    pub status: u16,
    /// L'adresse finale, après redirections.
    pub url: String,
    pub content_type: String,
    pub body: String,
}

/// Les cookies de la session, d'où qu'ils viennent dans WebView2. Les fenêtres de l'app
/// partagent le même profil, donc la principale les voit ; on interroge aussi les fenêtres
/// de connexion si elle n'en voit aucun (profil séparé, ou lecture refusée).
fn session_cookie(app: &AppHandle, url: &Url) -> String {
    let mut windows: Vec<tauri::WebviewWindow> = app.get_webview_window("main").into_iter().collect();
    windows.extend(app.webview_windows().into_iter().filter(|(label, _)| label.starts_with("site-")).map(|(_, w)| w));
    for window in windows {
        if let Ok(cookies) = window.cookies_for_url(url.clone()) {
            if !cookies.is_empty() {
                return cookie_header(cookies.iter().map(|c| (c.name().to_string(), c.value().to_string())));
            }
        }
    }
    String::new()
}

/// `a=1; b=2` : l'en-tête `Cookie` d'une liste de paires.
fn cookie_header(pairs: impl Iterator<Item = (String, String)>) -> String {
    pairs.map(|(name, value)| format!("{name}={value}")).collect::<Vec<_>>().join("; ")
}

async fn send(app: &AppHandle, state: &SiteState, req: SiteRequest) -> Result<reqwest::Response, String> {
    let url = Url::parse(&req.url).map_err(|e| e.to_string())?;
    if !allowed(state, &url) {
        return Err("Site non autorisé : connecte-toi d'abord.".into());
    }
    let cookie = session_cookie(app, &url);
    let client = reqwest::Client::builder()
        .timeout(Duration::from_secs(req.timeout.unwrap_or(20)))
        // Sans « Safari » dans l'agent, Moodle sert une page de cours sans ses sections.
        .user_agent("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Safari/537.36 Edg/130.0")
        .build()
        .map_err(|e| e.to_string())?;
    let method = reqwest::Method::from_bytes(req.method.as_deref().unwrap_or("GET").as_bytes()).map_err(|e| e.to_string())?;
    let mut builder = client.request(method, url);
    if !cookie.is_empty() {
        builder = builder.header("Cookie", cookie);
    }
    for (name, value) in req.headers.unwrap_or_default() {
        builder = builder.header(name, value);
    }
    if let Some(body) = req.body {
        builder = builder.body(body);
    }
    builder.send().await.map_err(|e| e.to_string())
}

/// Une requête avec la session ; le corps est rendu en texte.
#[tauri::command]
pub async fn site_request(app: AppHandle, state: State<'_, SiteState>, req: SiteRequest) -> Result<SiteResponse, String> {
    let response = send(&app, &state, req).await?;
    let status = response.status().as_u16();
    let url = response.url().to_string();
    let content_type = response
        .headers()
        .get("content-type")
        .and_then(|v| v.to_str().ok())
        .unwrap_or("")
        .to_string();
    // Un PDF ou une image n'est pas du texte : on n'en rend pas le contenu ici.
    let textual = content_type.is_empty() || content_type.contains("text") || content_type.contains("json") || content_type.contains("xml");
    let body = if textual { response.text().await.map_err(|e| e.to_string())? } else { String::new() };
    Ok(SiteResponse { status, url, content_type, body })
}

/// Un fichier (PDF…) téléchargé avec la session, rendu en octets bruts.
#[tauri::command]
pub async fn site_download(app: AppHandle, state: State<'_, SiteState>, req: SiteRequest) -> Result<tauri::ipc::Response, String> {
    let response = send(&app, &state, req).await?;
    if !response.status().is_success() {
        return Err(format!("HTTP {}", response.status().as_u16()));
    }
    let bytes = response.bytes().await.map_err(|e| e.to_string())?;
    Ok(tauri::ipc::Response::new(bytes.to_vec()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn base_domains() {
        assert_eq!(base_domain("moodle.epfl.ch"), "epfl.ch");
        assert_eq!(base_domain("epfl.ch"), "epfl.ch");
        assert_eq!(base_domain("a.b.c.example.org"), "example.org");
    }

    #[test]
    fn only_declared_https_domains_are_allowed() {
        let state = SiteState::default();
        state.domains.lock().unwrap().insert("epfl.ch".into());
        assert!(allowed(&state, &Url::parse("https://moodle.epfl.ch/my/").unwrap()));
        assert!(!allowed(&state, &Url::parse("http://moodle.epfl.ch/").unwrap()));
        assert!(!allowed(&state, &Url::parse("https://evil.com/").unwrap()));
    }

    #[test]
    fn saved_domains_are_checked() {
        assert!(is_domain("epfl.ch"));
        assert!(is_domain("moodle-test.example.org"));
        assert!(!is_domain(""));
        assert!(!is_domain("localhost"));
        assert!(!is_domain("evil.com/x"));
        assert!(!is_domain("a b.ch"));
    }

    #[test]
    fn cookie_header_joins_pairs() {
        let pairs = vec![("MoodleSession".to_string(), "abc".to_string()), ("x".to_string(), "1".to_string())];
        assert_eq!(cookie_header(pairs.into_iter()), "MoodleSession=abc; x=1");
    }
}
