//! Ed Discussion : la connexion dans une fenêtre d'edstem.org, puis la clé de l'app Ed rendue
//! à StudyTrack. Ed garde sa clé dans le stockage de sa propre page ; une page distante n'a pas
//! le droit d'appeler l'app, alors on lui fait **naviguer** vers une adresse sentinelle
//! (`https://studytrack.invalid/ed#région|clé`) que la fenêtre intercepte et annule : la clé
//! ne quitte jamais l'ordinateur. Elle est rangée dans le Gestionnaire d'identification
//! (`secrets.rs`, entrée `ed.token`) ; la fenêtre se ferme seule.

use tauri::webview::PageLoadEvent;
use tauri::{AppHandle, Emitter, Manager, Url, WebviewUrl, WebviewWindowBuilder};

const LABEL: &str = "site-ed";
const SENTINEL_HOST: &str = "studytrack.invalid";
pub const SECRET_KEY: &str = "ed.token";

/// Lit la clé dans la page d'Ed, chaque seconde pendant un quart d'heure : Ed change de page sans
/// recharger (la connexion finit sur le tableau de bord sans nouveau chargement). Rien n'est envoyé
/// ailleurs que vers l'adresse sentinelle.
const PROBE: &str = r#"(function(){if(window.__studytrackProbe)return;window.__studytrackProbe=true;var tries=0;var look=function(){try{var t=null,r='eu';for(var k=0;k<localStorage.length;k++){var key=localStorage.key(k);var v=(localStorage.getItem(key)||'').replace(/^"|"$/g,'');if(/authRegion/.test(key)&&v)r=v;if(/authToken/.test(key)&&!/device/i.test(key)&&v)t=v;}if(t){location.href='https://studytrack.invalid/ed#'+encodeURIComponent(r)+'|'+encodeURIComponent(t);return;}}catch(e){}if(++tries<900)setTimeout(look,1000);};look();})();"#;

/// `https://studytrack.invalid/ed#eu|abc` → (« eu », « abc »).
pub fn parse_sentinel(url: &Url) -> Option<(String, String)> {
    if url.host_str() != Some(SENTINEL_HOST) {
        return None;
    }
    let fragment = url.fragment()?;
    let (region, token) = fragment.split_once('|')?;
    let decode = |s: &str| urlencoding_decode(s);
    let region = decode(region);
    let token = decode(token);
    let region_ok = !region.is_empty() && region.len() <= 8 && region.chars().all(|c| c.is_ascii_lowercase());
    if !region_ok || token.is_empty() || token.len() > 4096 {
        return None;
    }
    Some((region, token))
}

fn urlencoding_decode(s: &str) -> String {
    let bytes = s.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' && i + 2 < bytes.len() {
            if let Ok(v) = u8::from_str_radix(&s[i + 1..i + 3], 16) {
                out.push(v);
                i += 3;
                continue;
            }
        }
        out.push(bytes[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

/// Ouvre la connexion à Ed (ou la remet devant). `region` : « eu » pour l'EPFL.
#[tauri::command]
pub async fn ed_sign_in(app: AppHandle, region: String) -> Result<(), String> {
    let region: String = region.chars().filter(|c| c.is_ascii_lowercase()).take(8).collect();
    let url = Url::parse(&format!("https://edstem.org/{}/login", if region.is_empty() { "eu" } else { &region }))
        .map_err(|e| e.to_string())?;
    let locked = super::kiosk::is_locked();
    if let Some(window) = app.get_webview_window(LABEL) {
        let _ = window.navigate(url);
        let _ = window.show();
        let _ = window.set_always_on_top(locked);
        let _ = window.set_focus();
        return Ok(());
    }
    let handle = app.clone();
    WebviewWindowBuilder::new(&app, LABEL, WebviewUrl::External(url))
        .title("Connexion à Ed")
        .inner_size(980.0, 760.0)
        .always_on_top(locked)
        .on_navigation(move |url| {
            let Some((region, token)) = parse_sentinel(url) else { return true };
            let _ = super::secrets::secret_set(SECRET_KEY.into(), Some(format!("{region}|{token}")));
            let _ = handle.emit("ed:signed-in", region);
            if let Some(window) = handle.get_webview_window(LABEL) {
                std::thread::spawn(move || {
                    std::thread::sleep(std::time::Duration::from_millis(300));
                    let _ = window.close();
                });
            }
            false
        })
        .on_page_load(|window, payload| {
            // Une fois connecté·e, chaque page d'Ed porte la clé : on la cherche à chaque chargement.
            if payload.event() == PageLoadEvent::Finished && payload.url().host_str().is_some_and(|h| h.ends_with("edstem.org")) {
                let _ = window.eval(PROBE);
            }
        })
        .build()
        .map_err(|e| e.to_string())?;
    Ok(())
}

/// Oublie la clé d'Ed (se déconnecter d'Ed dans l'app).
#[tauri::command]
pub fn ed_sign_out() -> Result<(), String> {
    super::secrets::secret_set(SECRET_KEY.into(), None)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_only_the_sentinel() {
        let ok = Url::parse("https://studytrack.invalid/ed#eu|abc%2Edef").unwrap();
        assert_eq!(parse_sentinel(&ok), Some(("eu".into(), "abc.def".into())));
        assert_eq!(parse_sentinel(&Url::parse("https://evil.example/ed#eu|abc").unwrap()), None);
        assert_eq!(parse_sentinel(&Url::parse("https://studytrack.invalid/ed#EU!|abc").unwrap()), None);
        assert_eq!(parse_sentinel(&Url::parse("https://studytrack.invalid/ed#eu|").unwrap()), None);
    }
}
