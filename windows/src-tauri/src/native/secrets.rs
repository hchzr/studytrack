//! Le coffre des secrets : jetons des fournisseurs de tâches, clé AnkiWeb,
//! session Supabase. Sous Windows, le Gestionnaire d'identification
//! (Credential Manager) ; sur le Mac de développement, le trousseau — le
//! pendant de `AnkiKeychain` et du trousseau de `SupabaseSessionStore`.
//! Rien n'est écrit en clair dans le stockage de la webview.

use std::collections::HashMap;

/// Le service sous lequel l'app range ses entrées (« StudyTrack:<clé> »).
const SERVICE: &str = "StudyTrack";

fn entry(key: &str) -> Result<keyring::Entry, String> {
    keyring::Entry::new(SERVICE, key).map_err(|e| e.to_string())
}

/// Lit d'un coup les secrets demandés : ceux qui manquent sont absents de la table.
#[tauri::command]
pub fn secrets_load(keys: Vec<String>) -> HashMap<String, String> {
    let mut found = HashMap::new();
    for key in keys {
        if let Ok(value) = entry(&key).and_then(|e| e.get_password().map_err(|e| e.to_string())) {
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
