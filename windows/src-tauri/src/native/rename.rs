//! StudyTrack → Polymestre : l'identifiant de l'app a changé
//! (`com.hczr.studytrack.windows` → `ch.polymestre.windows`), et avec lui les dossiers
//! de l'app — la base SQLite, les réglages de la webview (stockage local, cookies),
//! le chrono flottant, Claude. Avant que la webview ne s'ouvre, les anciens dossiers
//! sont **copiés** sous le nouveau nom, une fois (rien n'est copié si le nouveau
//! existe déjà), et la base prend son nouveau nom (`studytrack.db` → `polymestre.db`).
//! Les anciens dossiers restent : réinstaller l'ancienne version rend tout tel quel.

use std::fs;
use std::io;
use std::path::{Path, PathBuf};

const OLD_ID: &str = "com.hczr.studytrack.windows";
const NEW_ID: &str = "ch.polymestre.windows";

/// Les dossiers où Tauri range les fichiers d'une app (données, configuration, local).
fn roots() -> Vec<PathBuf> {
    let mut out = Vec::new();
    #[cfg(windows)]
    for var in ["APPDATA", "LOCALAPPDATA"] {
        if let Ok(value) = std::env::var(var) {
            out.push(PathBuf::from(value));
        }
    }
    #[cfg(target_os = "macos")]
    if let Ok(home) = std::env::var("HOME") {
        out.push(PathBuf::from(home).join("Library/Application Support"));
    }
    out
}

/// À appeler avant tout (avant la création des fenêtres).
pub fn adopt_legacy_folders() {
    for root in roots() {
        let old = root.join(OLD_ID);
        let new = root.join(NEW_ID);
        if let Err(error) = adopt(&old, &new) {
            eprintln!("reprise de {} : {error}", old.display());
        }
    }
}

/// Copie `old` vers `new` si `new` n'existe pas, puis renomme la base. Vrai si copié.
pub fn adopt(old: &Path, new: &Path) -> io::Result<bool> {
    if !old.is_dir() || new.exists() {
        return Ok(false);
    }
    // Copie dans un dossier provisoire, renommé à la fin : une copie interrompue ne
    // laisse pas un nouveau dossier à moitié rempli (qui empêcherait de recommencer).
    let staging = new.with_extension("copie");
    if staging.exists() {
        fs::remove_dir_all(&staging)?;
    }
    copy_dir(old, &staging)?;
    for suffix in ["", "-wal", "-shm", "-journal"] {
        let from = staging.join(format!("studytrack.db{suffix}"));
        if from.exists() {
            fs::rename(&from, staging.join(format!("polymestre.db{suffix}")))?;
        }
    }
    fs::rename(&staging, new)?;
    Ok(true)
}

fn copy_dir(from: &Path, to: &Path) -> io::Result<()> {
    fs::create_dir_all(to)?;
    for entry in fs::read_dir(from)? {
        let entry = entry?;
        let target = to.join(entry.file_name());
        let kind = entry.file_type()?;
        if kind.is_dir() {
            copy_dir(&entry.path(), &target)?;
        } else if kind.is_file() {
            // Un fichier verrouillé (webview encore ouverte) ne bloque pas le reste.
            if let Err(error) = fs::copy(entry.path(), &target) {
                eprintln!("copie de {} : {error}", entry.path().display());
            }
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn copies_once_and_renames_the_database() {
        let base = std::env::temp_dir().join(format!("polymestre-rename-{}", std::process::id()));
        let _ = fs::remove_dir_all(&base);
        let old = base.join(OLD_ID);
        let new = base.join(NEW_ID);
        fs::create_dir_all(old.join("EBWebView/Default")).unwrap();
        fs::write(old.join("studytrack.db"), b"base").unwrap();
        fs::write(old.join("studytrack.db-wal"), b"journal").unwrap();
        fs::write(old.join("EBWebView/Default/Local Storage"), b"stockage").unwrap();

        assert!(adopt(&old, &new).unwrap());
        assert_eq!(fs::read(new.join("polymestre.db")).unwrap(), b"base");
        assert_eq!(fs::read(new.join("polymestre.db-wal")).unwrap(), b"journal");
        assert_eq!(fs::read(new.join("EBWebView/Default/Local Storage")).unwrap(), b"stockage");
        assert!(!new.join("studytrack.db").exists());
        // L'ancien reste intact.
        assert_eq!(fs::read(old.join("studytrack.db")).unwrap(), b"base");
        // Une seconde fois : rien (le nouveau existe).
        fs::write(new.join("polymestre.db"), b"changed").unwrap();
        assert!(!adopt(&old, &new).unwrap());
        assert_eq!(fs::read(new.join("polymestre.db")).unwrap(), b"changed");
        let _ = fs::remove_dir_all(&base);
    }
}
