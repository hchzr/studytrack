//! La musique du mode étude sous Windows : ce qui joue dans le lecteur du système (Spotify,
//! Apple Music, un navigateur… — les « contrôles multimédias » de Windows), et le piloter :
//! lecture, pause, morceau suivant. Rien n'est lancé ni écouté en arrière-plan : chaque appel
//! lit l'état à l'instant, sur demande de l'écran.

use serde::Serialize;

#[derive(Serialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct MediaState {
    pub available: bool,
    pub playing: bool,
    pub title: String,
    pub artist: String,
    /// L'app qui joue (« Spotify.exe », « Chrome »…).
    pub app: String,
}

#[cfg(target_os = "windows")]
mod win {
    use super::MediaState;
    use windows::Media::Control::{
        GlobalSystemMediaTransportControlsSession as Session, GlobalSystemMediaTransportControlsSessionManager as Manager,
        GlobalSystemMediaTransportControlsSessionPlaybackStatus as Status,
    };
    use windows::Win32::System::WinRT::{RoInitialize, RO_INIT_MULTITHREADED};

    fn session() -> windows::core::Result<Session> {
        // SAFETY: initialise WinRT sur ce fil (déjà fait : sans effet).
        unsafe {
            let _ = RoInitialize(RO_INIT_MULTITHREADED);
        }
        Manager::RequestAsync()?.join()?.GetCurrentSession()
    }

    pub fn state() -> MediaState {
        let Ok(session) = session() else { return MediaState::default() };
        let playing = session.GetPlaybackInfo().and_then(|i| i.PlaybackStatus()).map(|s| s == Status::Playing).unwrap_or(false);
        let props = session.TryGetMediaPropertiesAsync().and_then(|op| op.join());
        let (title, artist) = props
            .map(|p| (p.Title().map(|t| t.to_string()).unwrap_or_default(), p.Artist().map(|a| a.to_string()).unwrap_or_default()))
            .unwrap_or_default();
        let app = session.SourceAppUserModelId().map(|s| s.to_string()).unwrap_or_default();
        MediaState { available: true, playing, title, artist, app }
    }

    pub fn command(action: &str) -> Result<(), String> {
        let session = session().map_err(|e| e.to_string())?;
        let op = match action {
            "toggle" => session.TryTogglePlayPauseAsync(),
            "play" => session.TryPlayAsync(),
            "pause" => session.TryPauseAsync(),
            "next" => session.TrySkipNextAsync(),
            "previous" => session.TrySkipPreviousAsync(),
            _ => return Err("Commande inconnue.".into()),
        };
        op.and_then(|op| op.join()).map(|_| ()).map_err(|e| e.to_string())
    }
}

/// Ce qui joue maintenant (`available: false` : rien, ou pas Windows).
#[tauri::command]
pub async fn media_state() -> MediaState {
    #[cfg(target_os = "windows")]
    {
        tauri::async_runtime::spawn_blocking(win::state).await.unwrap_or_default()
    }
    #[cfg(not(target_os = "windows"))]
    MediaState::default()
}

/// `toggle`, `play`, `pause`, `next`, `previous`.
#[tauri::command]
pub async fn media_command(action: String) -> Result<(), String> {
    #[cfg(target_os = "windows")]
    {
        tauri::async_runtime::spawn_blocking(move || win::command(&action)).await.map_err(|e| e.to_string())?
    }
    #[cfg(not(target_os = "windows"))]
    {
        let _ = action;
        Err("La musique du système se pilote sous Windows.".into())
    }
}
