//! Le coffre des secrets : jetons des fournisseurs de tâches, clé AnkiWeb,
//! session Supabase. Sous Windows, le Gestionnaire d'identification
//! (Credential Manager) ; sur le Mac de développement, le trousseau — le
//! pendant de `AnkiKeychain` et du trousseau de `SupabaseSessionStore`.
//! Rien n'est écrit en clair dans le stockage de la webview.

use std::collections::HashMap;

/// Le service sous lequel l'app range ses entrées (« Polymestre:<clé> »).
const SERVICE: &str = "Polymestre";
/// Celui de StudyTrack, avant le changement de nom : relu (jamais effacé) pour reprendre
/// un secret absent, sous l'ancien nom de clé (`studytrack.…`) ou le même.
const LEGACY_SERVICE: &str = "StudyTrack";

fn entry(key: &str) -> Result<keyring::Entry, String> {
    keyring::Entry::new(SERVICE, key).map_err(|e| e.to_string())
}

fn read(service: &str, key: &str) -> Option<String> {
    keyring::Entry::new(service, key).ok()?.get_password().ok()
}

/// Les noms sous lesquels StudyTrack a pu ranger ce secret.
pub fn legacy_names(key: &str) -> Vec<String> {
    let mut names = vec![key.to_string()];
    if let Some(rest) = key.strip_prefix("polymestre.") {
        names.insert(0, format!("studytrack.{rest}"));
    }
    names
}

/// Lit d'un coup les secrets demandés : ceux qui manquent sont absents de la table.
/// Un secret absent mais rangé par StudyTrack est recopié sous le nouveau nom.
#[tauri::command]
pub fn secrets_load(keys: Vec<String>) -> HashMap<String, String> {
    let mut found = HashMap::new();
    for key in keys {
        if let Some(value) = read(SERVICE, &key) {
            found.insert(key, value);
        } else if let Some(value) = legacy_names(&key).iter().find_map(|old| read(LEGACY_SERVICE, old)) {
            if let Ok(entry) = entry(&key) {
                let _ = entry.set_password(&value);
            }
            found.insert(key, value);
        }
    }
    found
}

/// Range un secret, ou l'efface (`None`, ou une chaîne vide).
#[tauri::command]
pub fn secret_set(key: String, value: Option<String>) -> Result<(), String> {
    let entry = entry(&key)?;
    match value {
        Some(v) if !v.is_empty() => entry.set_password(&v).map_err(|e| e.to_string()),
        _ => match entry.delete_credential() {
            Ok(()) | Err(keyring::Error::NoEntry) => Ok(()),
            Err(e) => Err(e.to_string()),
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn legacy_names_try_the_old_prefix_first() {
        assert_eq!(legacy_names("polymestre.supabase.session"), vec!["studytrack.supabase.session", "polymestre.supabase.session"]);
        assert_eq!(legacy_names("todoist.token"), vec!["todoist.token"]);
    }
}
