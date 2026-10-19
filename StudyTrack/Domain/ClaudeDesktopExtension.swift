import Foundation

/// L'extension « StudyTrack » de l'app Claude (Desktop) : un fichier `.mcpb` à
/// ouvrir d'un double-clic — l'app Claude propose de l'installer.
///
/// L'app Claude ne lance que des serveurs **locaux en stdio** et ne sait pas
/// ouvrir un chemin de fichier. L'extension est donc un petit pont, sans
/// dépendance, que l'app Claude fait tourner avec son propre Node :
/// - il relaie chaque requête au serveur local de StudyTrack (`LocalMCP`),
///   dont il lit l'adresse dans `local-mcp.json` — elle peut changer d'un
///   lancement à l'autre, rien n'est copié dans l'extension ;
/// - il demande `read_file` en mode « inline » : les pages d'un PDF reviennent en
///   **images**, le texte en texte — Claude les lit sans chemin ;
/// - si StudyTrack n'est pas ouvert, il l'ouvre (sans l'amener au premier plan).
enum ClaudeDesktopExtension {

    static let name = "studytrack-files"
    static let version = "1.0.0"

    /// Où l'app écrit l'adresse de son serveur local (lu par le pont).
    static func infoFile(home: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)) -> URL {
        home.appendingPathComponent("Library/Application Support/StudyTrack/local-mcp.json")
    }

    static func manifest() -> String {
        let manifest: [String: Any] = [
            "manifest_version": "0.4",
            "name": name,
            "display_name": "StudyTrack",
            "version": version,
            "description": "Tes cours, séries, corrigés, examens et notes, lus depuis StudyTrack sur ce Mac.",
            "long_description": "Donne à Claude tous tes PDF et documents d'étude : énoncés et corrigés de séries, anciens examens, supports de cours, ressources, cahiers de notes, notes et fiche de révision. Les pages des PDF arrivent en images (formules intactes). Demande « Fichiers pour Claude » dans les réglages de StudyTrack ; l'app s'ouvre toute seule si besoin.",
            "author": ["name": "StudyTrack"],
            "server": [
                "type": "node",
                "entry_point": "server/index.js",
                "mcp_config": ["command": "node", "args": ["${__dirname}/server/index.js"]],
            ],
            "tools": [
                ["name": "list_files", "description": "Liste les fichiers d'étude (cours, type, série, mots)."],
                ["name": "read_file", "description": "Lit un fichier : texte, ou pages d'un PDF en images."],
                ["name": "fetch_all_files", "description": "Prépare d'avance les fichiers d'un cours."],
            ],
            "tools_generated": false,
            "compatibility": ["platforms": ["darwin"], "runtimes": ["node": ">=18.0.0"]],
        ]
        let data = (try? JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// Le pont. Aucune dépendance : Node 18+ (celui de l'app Claude) suffit.
    /// `appID` : l'identifiant de l'app du Mac, pour la rouvrir si besoin.
    static func bridge(appID: String) -> String {
        script.replacingOccurrences(of: "__APP_ID__", with: appID)
    }

    /// Les fichiers de l'extension, par chemin relatif.
    static func files(appID: String) -> [String: Data] {
        ["manifest.json": Data(manifest().utf8), "server/index.js": Data(bridge(appID: appID).utf8)]
    }

    private static let script = #"""
    #!/usr/bin/env node
    // StudyTrack — pont entre l'app Claude (stdio) et le serveur MCP local de StudyTrack (HTTP, 127.0.0.1).
    'use strict';
    const fs = require('fs');
    const os = require('os');
    const path = require('path');
    const { spawn } = require('child_process');

    const INFO = process.env.STUDYTRACK_MCP_INFO ||
      path.join(os.homedir(), 'Library', 'Application Support', 'StudyTrack', 'local-mcp.json');
    const APP_ID = '__APP_ID__';
    // Réglables pour les essais : ne pas ouvrir l'app, et combien de temps l'attendre.
    const NO_LAUNCH = process.env.STUDYTRACK_MCP_NO_LAUNCH === '1';
    const WAIT_MS = Number(process.env.STUDYTRACK_MCP_WAIT_MS || 20000);
    const HINT = "StudyTrack ne répond pas. Ouvre l'app StudyTrack sur ce Mac et active Réglages › Mode étude › « Serveur local des fichiers », puis réessaie.";

    function readURL() {
      try { return JSON.parse(fs.readFileSync(INFO, 'utf8')).url || null; } catch (e) { return null; }
    }

    async function post(url, body) {
      const response = await fetch(url, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(body),
        signal: AbortSignal.timeout(180000),
      });
      if (response.status === 202) return null;
      const text = await response.text();
      return text ? JSON.parse(text) : null;
    }

    async function alive(url) {
      try { await post(url, { jsonrpc: '2.0', id: 'ping', method: 'ping' }); return true; } catch (e) { return false; }
    }

    let launched = false;
    async function serverURL() {
      let url = readURL();
      if (url && await alive(url)) return url;
      // Pas là : on ouvre l'app (en arrière-plan) et on attend qu'elle écoute.
      if (!launched && !NO_LAUNCH && process.platform === 'darwin') {
        launched = true;
        try { spawn('open', ['-g', '-b', APP_ID], { stdio: 'ignore', detached: true }).unref(); } catch (e) { /* tant pis */ }
      }
      for (let i = 0; i < Math.ceil(WAIT_MS / 500); i++) {
        await new Promise((resolve) => setTimeout(resolve, 500));
        url = readURL();
        if (url && await alive(url)) return url;
      }
      return null;
    }

    function failure(message, text) {
      if (message.method === 'tools/call') {
        return { jsonrpc: '2.0', id: message.id, result: { content: [{ type: 'text', text }], isError: true } };
      }
      return { jsonrpc: '2.0', id: message.id, error: { code: -32000, message: text } };
    }

    async function relay(message) {
      // Claude ne sait pas ouvrir un chemin : read_file rend les pages en images, le texte en texte.
      if (message.method === 'tools/call' && message.params && message.params.name === 'read_file') {
        message.params.arguments = Object.assign({}, message.params.arguments, { inline: true });
      }
      const url = await serverURL();
      if (!url) return message.id === undefined ? null : failure(message, HINT);
      try {
        return await post(url, message);
      } catch (e) {
        return message.id === undefined ? null : failure(message, HINT + ' (' + e.message + ')');
      }
    }

    let buffer = '';
    process.stdin.setEncoding('utf8');
    process.stdin.on('data', (chunk) => {
      buffer += chunk;
      let newline;
      while ((newline = buffer.indexOf('\n')) >= 0) {
        const line = buffer.slice(0, newline).trim();
        buffer = buffer.slice(newline + 1);
        if (!line) continue;
        let message;
        try { message = JSON.parse(line); } catch (e) { continue; }
        // Les requêtes partent en parallèle ; chaque réponse s'écrit d'un bloc.
        relay(message).then((reply) => {
          if (reply) process.stdout.write(JSON.stringify(reply) + '\n');
        });
      }
    });
    process.stdin.on('end', () => process.exit(0));
    """#
}
