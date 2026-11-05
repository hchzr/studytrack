//! « Continuer avec Google » : le retour d'OAuth par une boucle locale (RFC 8252 §7.3).
//!
//! Google refuse OAuth dans une webview intégrée (403 `disallowed_useragent`, WebView2
//! compris). La connexion se fait donc dans le **navigateur du système**, et GoTrue renvoie
//! vers `http://127.0.0.1:<port>/auth-callback?code=…`. `oauth_start` ouvre ce port le temps
//! d'une connexion : un seul fil, bloqué dans `accept` (aucun sondage), qui s'arrête au
//! premier retour valide, à `oauth_cancel`, à un nouvel `oauth_start`, ou après cinq minutes.
//! Rien n'écoute le reste du temps.

use std::io::{Read, Write};
use std::net::{Ipv4Addr, TcpListener, TcpStream};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use tauri::{AppHandle, Emitter, Manager, State};

pub const CALLBACK_PATH: &str = "/auth-callback";
/// Durée maximale d'une connexion.
const TIMEOUT: Duration = Duration::from_secs(5 * 60);

#[derive(Default)]
pub struct OAuthState {
    current: Mutex<Option<Session>>,
}

struct Session {
    port: u16,
    stop: Arc<AtomicBool>,
}

impl Session {
    /// Arrête l'écoute : le drapeau, puis une connexion à soi-même pour réveiller `accept`.
    fn stop(&self) {
        self.stop.store(true, Ordering::SeqCst);
        let _ = TcpStream::connect((Ipv4Addr::LOCALHOST, self.port));
    }
}

/// La ligne de requête → chemin et requête si c'est `GET /auth-callback?…`, sinon `None`
/// (favicon, autre méthode, requête mal formée).
pub fn parse_request_line(line: &str) -> Option<String> {
    let mut parts = line.trim_end().split(' ');
    let (method, target, version) = (parts.next()?, parts.next()?, parts.next()?);
    if method != "GET" || !version.starts_with("HTTP/") || parts.next().is_some() {
        return None;
    }
    let path = target.split('?').next()?;
    if path != CALLBACK_PATH {
        return None;
    }
    Some(target.to_string())
}

/// Le retour porte-t-il une erreur (`error` ou `error_description` dans la requête) ?
pub fn is_error(target: &str) -> bool {
    target.split_once('?').is_some_and(|(_, q)| {
        q.split('&').any(|p| p.starts_with("error=") || p.starts_with("error_description="))
    })
}

/// La page montrée dans le navigateur, une fois le retour reçu.
pub fn page(target: &str) -> String {
    let (title, text) = if is_error(target) {
        ("Connexion impossible", "La connexion a échoué. Tu peux fermer cet onglet et réessayer dans Polymestre.")
    } else {
        ("Connexion réussie", "Connexion réussie — tu peux revenir dans Polymestre.")
    };
    format!(
        "<!doctype html><html lang=\"fr\"><head><meta charset=\"utf-8\"><title>{title}</title>\
         <meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"></head>\
         <body style=\"font-family:system-ui,sans-serif;display:grid;place-items:center;min-height:100vh;margin:0\">\
         <p style=\"font-size:1.2rem;text-align:center;padding:2rem\">{text}</p></body></html>"
    )
}

fn respond(stream: &mut TcpStream, status: &str, body: &str) {
    let head = format!(
        "HTTP/1.1 {status}\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: {}\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n",
        body.len()
    );
    let _ = stream.write_all(head.as_bytes());
    let _ = stream.write_all(body.as_bytes());
    let _ = stream.flush();
}

/// La première ligne de la requête (lue avec un délai court : un client muet ne bloque pas).
fn read_request_line(stream: &mut TcpStream) -> Option<String> {
    stream.set_read_timeout(Some(Duration::from_secs(5))).ok()?;
    let mut buf = Vec::new();
    let mut chunk = [0u8; 1024];
    while buf.len() < 8192 && !buf.contains(&b'\n') {
        let n = stream.read(&mut chunk).ok()?;
        if n == 0 {
            break;
        }
        buf.extend_from_slice(&chunk[..n]);
    }
    let end = buf.iter().position(|&b| b == b'\n').unwrap_or(buf.len());
    String::from_utf8(buf[..end].to_vec()).ok()
}

fn serve(app: AppHandle, listener: TcpListener, port: u16, stop: Arc<AtomicBool>) {
    for incoming in listener.incoming() {
        if stop.load(Ordering::SeqCst) {
            return;
        }
        let Ok(mut stream) = incoming else { continue };
        let target = read_request_line(&mut stream).and_then(|line| parse_request_line(&line));
        match target {
            Some(target) => {
                respond(&mut stream, "200 OK", &page(&target));
                stop.store(true, Ordering::SeqCst);
                let _ = app.emit_to("main", "oauth:callback", format!("http://127.0.0.1:{port}{target}"));
                if let Some(window) = app.get_webview_window("main") {
                    let _ = window.show();
                    let _ = window.unminimize();
                    let _ = window.set_focus();
                }
                return;
            }
            None => respond(&mut stream, "404 Not Found", ""),
        }
    }
}

/// Ouvre l'écoute sur la boucle locale (le port demandé, sinon un libre) et rend le port. Un nouvel appel annule le précédent.
#[tauri::command]
pub async fn oauth_start(app: AppHandle, state: State<'_, OAuthState>, port: Option<u16>) -> Result<u16, String> {
    // Un port fixe pour les fournisseurs qui exigent l'adresse exacte (Spotify) ; sinon un port libre.
    let listener = TcpListener::bind((Ipv4Addr::LOCALHOST, port.unwrap_or(0)))
        .map_err(|e| format!("Port {} occupé : ferme l'autre connexion en cours. ({e})", port.unwrap_or(0)))?;
    let port = listener.local_addr().map_err(|e| e.to_string())?.port();
    let stop = Arc::new(AtomicBool::new(false));
    if let Ok(mut current) = state.current.lock() {
        if let Some(previous) = current.take() {
            previous.stop();
        }
        *current = Some(Session { port, stop: stop.clone() });
    }
    let served = stop.clone();
    let server_app = app.clone();
    std::thread::spawn(move || serve(server_app, listener, port, served));
    // Le délai : un fil qui dort (aucun coût), puis ferme si rien n'est venu.
    let timer_app = app.clone();
    std::thread::spawn(move || {
        std::thread::sleep(TIMEOUT);
        if !stop.load(Ordering::SeqCst) {
            stop.store(true, Ordering::SeqCst);
            let _ = TcpStream::connect((Ipv4Addr::LOCALHOST, port));
            let _ = timer_app.emit_to("main", "oauth:timeout", ());
        }
    });
    Ok(port)
}

/// Ferme l'écoute en cours (bouton « Annuler »).
#[tauri::command]
pub async fn oauth_cancel(state: State<'_, OAuthState>) -> Result<(), String> {
    if let Ok(mut current) = state.current.lock() {
        if let Some(session) = current.take() {
            session.stop();
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn valid_callback_keeps_path_and_query() {
        assert_eq!(parse_request_line("GET /auth-callback?code=abc&state=x HTTP/1.1\r\n").as_deref(), Some("/auth-callback?code=abc&state=x"));
        assert_eq!(parse_request_line("GET /auth-callback?error=access_denied&error_description=No HTTP/1.1").as_deref(), Some("/auth-callback?error=access_denied&error_description=No"));
        assert_eq!(parse_request_line("GET /auth-callback HTTP/1.1").as_deref(), Some("/auth-callback"));
    }

    #[test]
    fn everything_else_is_ignored() {
        assert_eq!(parse_request_line("GET /favicon.ico HTTP/1.1"), None);
        assert_eq!(parse_request_line("GET / HTTP/1.1"), None);
        assert_eq!(parse_request_line("GET /auth-callbackX?code=1 HTTP/1.1"), None);
        assert_eq!(parse_request_line("GET /other/auth-callback?code=1 HTTP/1.1"), None);
        assert_eq!(parse_request_line("POST /auth-callback?code=1 HTTP/1.1"), None);
        assert_eq!(parse_request_line("GET /auth-callback?code=1"), None);
        assert_eq!(parse_request_line("GET /auth-callback?code=1 FTP/1.1"), None);
        assert_eq!(parse_request_line("GET /auth-callback?code=1 HTTP/1.1 extra"), None);
        assert_eq!(parse_request_line(""), None);
        assert_eq!(parse_request_line("\u{0}\u{1}garbage"), None);
    }

    #[test]
    fn page_tells_success_or_failure_in_french() {
        assert!(page("/auth-callback?code=1").contains("Connexion réussie — tu peux revenir dans Polymestre."));
        assert!(is_error("/auth-callback?error=access_denied"));
        assert!(!is_error("/auth-callback?code=1"));
        assert!(page("/auth-callback?error_description=x").contains("a échoué"));
    }

    #[test]
    fn listener_serves_one_callback_and_ignores_favicon() {
        // Le serveur lui-même, sans fenêtre : ni `AppHandle` ni émission ici, juste l'échange HTTP.
        let listener = TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).unwrap();
        let port = listener.local_addr().unwrap().port();
        let handle = std::thread::spawn(move || {
            let mut results = Vec::new();
            for incoming in listener.incoming() {
                let mut stream = incoming.unwrap();
                let line = read_request_line(&mut stream).unwrap();
                match parse_request_line(&line) {
                    Some(t) => { respond(&mut stream, "200 OK", &page(&t)); results.push(t); break; }
                    None => respond(&mut stream, "404 Not Found", ""),
                }
            }
            results
        });
        let mut fav = TcpStream::connect((Ipv4Addr::LOCALHOST, port)).unwrap();
        fav.write_all(b"GET /favicon.ico HTTP/1.1\r\nHost: x\r\n\r\n").unwrap();
        let mut reply = String::new();
        fav.read_to_string(&mut reply).unwrap();
        assert!(reply.starts_with("HTTP/1.1 404"));
        let mut ok = TcpStream::connect((Ipv4Addr::LOCALHOST, port)).unwrap();
        ok.write_all(b"GET /auth-callback?code=zz HTTP/1.1\r\nHost: x\r\n\r\n").unwrap();
        let mut reply = String::new();
        ok.read_to_string(&mut reply).unwrap();
        assert!(reply.starts_with("HTTP/1.1 200") && reply.contains("charset=utf-8") && reply.contains("Connexion réussie"));
        assert_eq!(handle.join().unwrap(), vec!["/auth-callback?code=zz".to_string()]);
    }
}
