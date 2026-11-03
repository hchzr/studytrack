//! Claude dans le mode étude, **par l'abonnement** de l'étudiant·e : un processus `claude`
//! (Claude Code, déjà connecté à son compte) par conversation, comme ClaudeChat.swift du Mac.
//! Les arguments, les messages et la lecture du flux sont côté TypeScript (`ClaudeTutor`, pur et
//! testé) ; ici, seulement : trouver `claude`, le lancer sans fenêtre de console, lui passer des
//! lignes, rendre ses lignes à l'app (`claude:line`), dire quand il s'arrête (`claude:exit`).
//! Rien ne tourne entre deux conversations : le processus naît à l'envoi et meurt à la fermeture.

use std::collections::HashMap;
use std::io::{BufRead, BufReader, Read, Write};
use std::path::PathBuf;
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::Mutex;

use serde::Serialize;
use tauri::{AppHandle, Emitter, Manager, State};

#[derive(Default)]
pub struct ClaudeState {
    running: Mutex<HashMap<String, (Child, ChildStdin)>>,
}

#[derive(Serialize, Clone)]
struct Line {
    key: String,
    line: String,
}

#[derive(Serialize, Clone)]
struct Exit {
    key: String,
    code: Option<i32>,
    stderr: String,
}

fn home() -> Option<PathBuf> {
    std::env::var_os("USERPROFILE").or_else(|| std::env::var_os("HOME")).map(PathBuf::from)
}

/// Où chercher `claude` : l'installeur natif (`~/.local/bin/claude.exe`), puis le `PATH`.
pub fn find_claude() -> Option<PathBuf> {
    let exe = if cfg!(windows) { "claude.exe" } else { "claude" };
    let mut candidates: Vec<PathBuf> = Vec::new();
    if let Some(home) = home() {
        candidates.push(home.join(".local").join("bin").join(exe));
        candidates.push(home.join(".claude").join("local").join(exe));
        candidates.push(home.join(".bun").join("bin").join(exe));
    }
    if let Some(path) = std::env::var_os("PATH") {
        candidates.extend(std::env::split_paths(&path).map(|dir| dir.join(exe)));
    }
    if !cfg!(windows) {
        candidates.push(PathBuf::from("/opt/homebrew/bin/claude"));
        candidates.push(PathBuf::from("/usr/local/bin/claude"));
    }
    candidates.into_iter().find(|path| path.is_file())
}

/// Le dossier de travail des conversations (Claude Code y range ses sessions par dossier).
fn workdir(app: &AppHandle) -> Result<PathBuf, String> {
    let dir = app.path().app_data_dir().map_err(|e| e.to_string())?.join("claude");
    std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    Ok(dir)
}

#[derive(Serialize)]
pub struct ClaudeSetup {
    /// `claude` trouvé ?
    pub found: bool,
    /// Le dossier de travail (pour retrouver les sessions et l'historique).
    pub workdir: String,
}

#[tauri::command]
pub fn claude_setup(app: AppHandle) -> Result<ClaudeSetup, String> {
    Ok(ClaudeSetup { found: find_claude().is_some(), workdir: workdir(&app)?.to_string_lossy().into_owned() })
}

/// Lance une conversation (`key` : la série). `args` viennent de `ClaudeTutor.arguments`.
#[tauri::command]
pub fn claude_start(app: AppHandle, state: State<'_, ClaudeState>, key: String, args: Vec<String>) -> Result<(), String> {
    claude_stop(state.clone(), key.clone());
    let program = find_claude().ok_or("Claude Code n'est pas installé sur ce PC.")?;
    let mut command = Command::new(program);
    command.args(&args).current_dir(workdir(&app)?).stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::piped());
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        // Pas de fenêtre de console qui clignote derrière l'app.
        command.creation_flags(0x0800_0000);
    }
    let mut child = command.spawn().map_err(|e| format!("Claude Code ne démarre pas : {e}"))?;
    let stdin = child.stdin.take().ok_or("Pas d'entrée pour Claude Code.")?;
    let stdout = child.stdout.take().ok_or("Pas de sortie pour Claude Code.")?;
    let mut stderr = child.stderr.take().ok_or("Pas de sortie d'erreur pour Claude Code.")?;

    let errors = std::sync::Arc::new(Mutex::new(String::new()));
    let sink = errors.clone();
    std::thread::spawn(move || {
        let mut text = String::new();
        let _ = stderr.read_to_string(&mut text);
        if let Ok(mut all) = sink.lock() {
            all.push_str(&text);
        }
    });
    let handle = app.clone();
    let reading = key.clone();
    std::thread::spawn(move || {
        for line in BufReader::new(stdout).lines().map_while(Result::ok) {
            let _ = handle.emit("claude:line", Line { key: reading.clone(), line });
        }
        // La sortie est fermée : le processus s'arrête. On attend son code.
        let code = handle
            .state::<ClaudeState>()
            .running
            .lock()
            .ok()
            .and_then(|mut running| running.remove(&reading))
            .and_then(|(mut child, _)| child.wait().ok())
            .and_then(|status| status.code());
        std::thread::sleep(std::time::Duration::from_millis(100));
        let stderr = errors.lock().map(|text| text.clone()).unwrap_or_default();
        let _ = handle.emit("claude:exit", Exit { key: reading, code, stderr });
    });
    state.running.lock().map_err(|e| e.to_string())?.insert(key, (child, stdin));
    Ok(())
}

/// Une ligne JSON (`--input-format stream-json`) vers la conversation.
#[tauri::command]
pub fn claude_send(state: State<'_, ClaudeState>, key: String, line: String) -> Result<(), String> {
    let mut running = state.running.lock().map_err(|e| e.to_string())?;
    let (_, stdin) = running.get_mut(&key).ok_or("Conversation fermée.")?;
    stdin.write_all(line.as_bytes()).map_err(|e| e.to_string())?;
    stdin.write_all(b"\n").map_err(|e| e.to_string())?;
    stdin.flush().map_err(|e| e.to_string())
}

/// Ferme la conversation (le processus s'arrête ; la session reste sur le disque).
#[tauri::command]
pub fn claude_stop(state: State<'_, ClaudeState>, key: String) {
    if let Ok(mut running) = state.running.lock() {
        if let Some((mut child, _)) = running.remove(&key) {
            let _ = child.kill();
        }
    }
}

/// L'historique d'une session (le fichier `.jsonl` de Claude Code), pour la réafficher.
#[tauri::command]
pub fn claude_history(folder: String, session: String) -> Result<Option<String>, String> {
    let valid = |s: &str| !s.is_empty() && s.chars().all(|c| c.is_ascii_alphanumeric() || c == '-');
    if !valid(&folder) || !valid(&session) {
        return Err("Session invalide.".into());
    }
    let Some(home) = home() else { return Ok(None) };
    let file = home.join(".claude").join("projects").join(folder).join(format!("{session}.jsonl"));
    Ok(std::fs::read_to_string(file).ok())
}

/// À la sortie de l'app : aucune conversation ne survit.
pub fn shutdown(state: &ClaudeState) {
    if let Ok(mut running) = state.running.lock() {
        for (_, (mut child, _)) in running.drain() {
            let _ = child.kill();
        }
    }
}
