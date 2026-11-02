//! Blocage des sites par le fichier `hosts` (au mieux : demande les droits
//! administrateur). Le bloc écrit est balisé : le retirer ne touche à rien d'autre.

use std::fs::{self, OpenOptions};
use std::io::ErrorKind;
use std::path::{Path, PathBuf};

pub const BEGIN: &str = "# >>> StudyTrack blocage (ne pas modifier) >>>";
pub const END: &str = "# <<< StudyTrack blocage <<<";

#[derive(Debug, PartialEq, Eq)]
pub enum Outcome {
    Blocked,
    NeedsAdmin,
    Failed(String),
}

#[cfg(target_os = "windows")]
pub fn default_path() -> PathBuf {
    let root = std::env::var("SystemRoot").unwrap_or_else(|_| "C:\\Windows".into());
    PathBuf::from(root).join("System32").join("drivers").join("etc").join("hosts")
}

#[cfg(not(target_os = "windows"))]
pub fn default_path() -> PathBuf {
    PathBuf::from("/etc/hosts")
}

/// Un domaine sûr à écrire dans `hosts` : lettres, chiffres, points, tirets.
pub fn sanitize_domain(entry: &str) -> Option<String> {
    let mut text = entry.trim().to_lowercase();
    if let Some(i) = text.find("://") {
        text = text[i + 3..].to_string();
    }
    if let Some(i) = text.find(['/', '?', '#']) {
        text.truncate(i);
    }
    if let Some(stripped) = text.strip_prefix("www.") {
        text = stripped.to_string();
    }
    let valid = text.contains('.')
        && !text.starts_with('.')
        && !text.ends_with('.')
        && !text.contains("..")
        && !text.starts_with('-')
        && text.chars().all(|c| c.is_ascii_alphanumeric() || c == '.' || c == '-');
    valid.then_some(text)
}

/// Le contenu sans le bloc StudyTrack (s'il y en a un).
pub fn strip_block(content: &str) -> String {
    let crlf = content.contains("\r\n");
    let mut out: Vec<&str> = Vec::new();
    let mut inside = false;
    for line in content.lines() {
        let trimmed = line.trim();
        if trimmed == BEGIN {
            inside = true;
            continue;
        }
        if inside {
            if trimmed == END {
                inside = false;
            }
            continue;
        }
        out.push(line);
    }
    let eol = if crlf { "\r\n" } else { "\n" };
    let mut text = out.join(eol);
    if content.ends_with('\n') && !text.is_empty() {
        text.push_str(eol);
    }
    text
}

/// Le contenu avec un bloc neuf (l'ancien est remplacé).
pub fn with_block(content: &str, domains: &[String]) -> String {
    let crlf = content.contains("\r\n");
    let eol = if crlf { "\r\n" } else { "\n" };
    let mut text = strip_block(content);
    if !text.is_empty() && !text.ends_with('\n') {
        text.push_str(eol);
    }
    text.push_str(BEGIN);
    text.push_str(eol);
    for domain in domains {
        for host in [domain.clone(), format!("www.{domain}")] {
            text.push_str(&format!("0.0.0.0 {host}{eol}"));
        }
    }
    text.push_str(END);
    text.push_str(eol);
    text
}

/// Peut-on écrire dans le fichier ? (ouvre en ajout, n'écrit rien.)
pub fn writable(path: &Path) -> bool {
    OpenOptions::new().append(true).open(path).is_ok()
}

pub fn apply(path: &Path, domains: &[String]) -> Outcome {
    let content = match fs::read_to_string(path) {
        Ok(text) => text,
        Err(error) => return Outcome::Failed(error.to_string()),
    };
    match fs::write(path, with_block(&content, domains)) {
        Ok(()) => Outcome::Blocked,
        Err(error) if error.kind() == ErrorKind::PermissionDenied => Outcome::NeedsAdmin,
        Err(error) => Outcome::Failed(error.to_string()),
    }
}

/// Retire le bloc ; `Ok(true)` si le fichier a changé. N'écrit jamais s'il n'y a rien à retirer
/// (donc ne demande pas de droits pour rien, au démarrage).
pub fn restore(path: &Path) -> Result<bool, String> {
    let content = match fs::read_to_string(path) {
        Ok(text) => text,
        Err(error) if error.kind() == ErrorKind::NotFound => return Ok(false),
        Err(error) => return Err(error.to_string()),
    };
    if !content.contains(BEGIN) {
        return Ok(false);
    }
    fs::write(path, strip_block(&content)).map_err(|error| error.to_string())?;
    Ok(true)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sanitizes() {
        assert_eq!(sanitize_domain("https://www.YouTube.com/watch?v=1"), Some("youtube.com".into()));
        assert_eq!(sanitize_domain("reddit.com"), Some("reddit.com".into()));
        assert_eq!(sanitize_domain("localhost"), None);
        assert_eq!(sanitize_domain("a b.com"), None);
        assert_eq!(sanitize_domain("evil.com\n0.0.0.0 x"), None);
    }

    #[test]
    fn block_roundtrip_lf() {
        let original = "127.0.0.1 localhost\n# note\n";
        let blocked = with_block(original, &["youtube.com".to_string()]);
        assert!(blocked.contains("0.0.0.0 youtube.com\n0.0.0.0 www.youtube.com\n"));
        assert_eq!(strip_block(&blocked), original);
    }

    #[test]
    fn block_roundtrip_crlf_and_replace() {
        let original = "127.0.0.1 localhost\r\n";
        let once = with_block(original, &["a.com".to_string()]);
        let twice = with_block(&once, &["b.com".to_string()]);
        assert!(!twice.contains("a.com") && twice.contains("b.com"));
        assert_eq!(twice.matches(BEGIN).count(), 1);
        assert_eq!(strip_block(&twice), original);
        assert!(twice.contains("\r\n") && !twice.replace("\r\n", "").contains('\n'));
    }

    #[test]
    fn missing_final_newline_is_added_once() {
        let blocked = with_block("127.0.0.1 localhost", &["a.com".to_string()]);
        assert_eq!(strip_block(&blocked), "127.0.0.1 localhost\n");
    }

    #[test]
    fn file_apply_and_restore() {
        let dir = std::env::temp_dir().join(format!("studytrack-hosts-{}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        let path = dir.join("hosts");
        fs::write(&path, "127.0.0.1 localhost\n").unwrap();
        assert_eq!(apply(&path, &["x.com".to_string()]), Outcome::Blocked);
        assert!(fs::read_to_string(&path).unwrap().contains("0.0.0.0 x.com"));
        assert_eq!(restore(&path), Ok(true));
        assert_eq!(fs::read_to_string(&path).unwrap(), "127.0.0.1 localhost\n");
        assert_eq!(restore(&path), Ok(false));
        let _ = fs::remove_dir_all(&dir);
    }
}
