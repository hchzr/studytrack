# Serveur MCP StudyTrack

Expose tes données d'étude à un assistant — Claude Desktop, Claude Code, ou tout
client MCP. **Aucune dépendance** : le protocole tient dans la bibliothèque standard
de Node.

## 1. Produire l'instantané

Dans l'app : **Profil › Données › « Exporter pour un assistant »**, puis enregistre
le fichier sur ton Mac à l'emplacement par défaut :

```
~/.studytrack/studytrack-assistant.json
```

Un autre emplacement fonctionne aussi : voir `STUDYTRACK_EXPORT` ci-dessous.

L'instantané contient tes cours, séries, exercices, théorie, évaluations, sessions
de travail, échéances et groupes. Il ne contient **ni jeton, ni compte, ni identité
de membre** : un fichier qu'on partage ne doit pas transporter d'identités.

## 2. Brancher l'assistant

### Claude Code

```bash
claude mcp add studytrack -- node /chemin/vers/studytrack/mcp/server.js
```

### Claude Desktop

Dans `~/Library/Application Support/Claude/claude_desktop_config.json` :

```json
{
  "mcpServers": {
    "studytrack": {
      "command": "node",
      "args": ["/chemin/vers/studytrack/mcp/server.js"]
    }
  }
}
```

### Autre emplacement d'instantané

```json
{
  "mcpServers": {
    "studytrack": {
      "command": "node",
      "args": ["/chemin/vers/studytrack/mcp/server.js"],
      "env": { "STUDYTRACK_EXPORT": "/chemin/vers/studytrack-assistant.json" }
    }
  }
}
```

## 3. Les outils

| Outil | Ce qu'il répond |
|---|---|
| `study_overview` | Temps des 7 et 30 derniers jours, répartition par cours et par type, jours actifs d'affilée |
| `list_courses` | Cours suivis : crédits, avancement en exercices et en théorie, nombre d'évaluations |
| `what_to_do` | Ce qu'il reste : séries en retard, exercices à corriger ou à refaire, théorie à voir ou à résumer |
| `coverage` | Ce qui échappe au suivi : cours vide, série sans exercice, série en retard, évaluation absente, vidéo sans durée |
| `search` | Cherche un mot dans les cours, les séries, les exercices (titre **et** note de correction) et la théorie (titre **et** résumé) |
| `upcoming_dates` | Échéances du calendrier académique de l'EPFL et évaluations des cours |
| `study_time` | Temps par cours et par type sur une fenêtre de N jours |

Exemples de questions qui passent par là :

- « Qu'est-ce que je dois faire cette semaine ? » → `what_to_do`
- « Il me reste combien de temps avant les examens ? » → `upcoming_dates`
- « Où en est mon cours de maths ? » → `list_courses`
- « Montre-moi tout ce qui n'est pas corrigé » → `coverage`
- « Combien de temps ai-je travaillé hier ? » → `study_time`

## 4. En lecture seule

Les outils **consultent**, ils n'écrivent pas. Faire modifier ses données d'étude
par un modèle de langage demanderait une relecture humaine que ce serveur n'a pas
les moyens d'offrir — marquer un exercice « fait » par erreur fausse le suivi et
les statistiques. La prochaine étape, si elle vient, passera par des commandes
**relues dans l'app** avant d'être appliquées.

## 5. Vérifier

```bash
printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"study_overview","arguments":{}}}' \
  | node mcp/server.js
```
