import Foundation

/// Ce que la Live Activity doit afficher, et comment le temps s'y écoule.
///
/// **Type pur, sans ActivityKit** : c'est ce qui permet de le tester sur macOS,
/// sans simulateur ni écran verrouillé — et c'est précisément là que se trouvait
/// le bogue.
///
/// L'ancienne version portait `accumulated` **et** `runningSince`, et le compteur
/// système n'affichait que le second : après une pause, il repartait de zéro et
/// annonçait « 00:01 » au lieu d'une heure de travail. Ici, `countingSince` est
/// l'instant de départ **reculé du total déjà écoulé** — `Text(timerInterval:)`
/// affiche donc le total, et continue d'avancer.
struct ActivityTimerState: Codable, Hashable {
    /// Instant depuis lequel le **total** s'écoule. `nil` quand c'est en pause.
    var countingSince: Date?

    /// Le total, figé, quand le chrono est en pause.
    var frozenTotal: TimeInterval

    /// Sous-questions cochées de la cible, et combien il y en a.
    ///
    /// Optionnels, et pas `0` par défaut : une session sans cible n'a pas
    /// « 0/0 » sous-questions, elle n'en a **pas**. C'est aussi ce qui permet à
    /// une activité publiée par une version précédente de se décoder — un
    /// `Optional` absent vaut `nil`, là où un `Int` manquant ferait échouer tout
    /// le décodage et laisserait l'îlot figé sur un état mort.
    var questionsDone: Int?
    var questionsTotal: Int?

    /// Le bloc Pomodoro en cours, quand la session est en Pomodoro.
    var pomodoro: ActivityPomodoro?

    init(countingSince: Date?,
         frozenTotal: TimeInterval,
         questionsDone: Int? = nil,
         questionsTotal: Int? = nil,
         pomodoro: ActivityPomodoro? = nil) {
        self.countingSince = countingSince
        self.frozenTotal = frozenTotal
        self.questionsDone = questionsDone
        self.questionsTotal = questionsTotal
        self.pomodoro = pomodoro
    }

    /// Construit l'état à publier.
    ///
    /// - Parameters:
    ///   - elapsed: le total réel déjà travaillé.
    ///   - running: le chrono continue-t-il de s'écouler ?
    ///   - questionsDone: sous-questions déjà cochées, s'il y en a.
    ///   - questionsTotal: sous-questions de la cible, s'il y en a.
    ///   - pomodoro: le bloc en cours, si la session est en Pomodoro.
    ///   - now: l'instant de référence, injectable pour les tests.
    static func make(elapsed: TimeInterval,
                     running: Bool,
                     questionsDone: Int? = nil,
                     questionsTotal: Int? = nil,
                     pomodoro: ActivityPomodoro? = nil,
                     now: Date = Date()) -> ActivityTimerState {
        let total = max(0, elapsed)
        return ActivityTimerState(countingSince: running ? now.addingTimeInterval(-total) : nil,
                                  frozenTotal: total,
                                  questionsDone: questionsDone,
                                  questionsTotal: questionsTotal,
                                  pomodoro: pomodoro)
    }

    var isRunning: Bool { countingSince != nil }

    /// Total écoulé à cet instant.
    func elapsed(at now: Date = Date()) -> TimeInterval {
        guard let countingSince else { return frozenTotal }
        return max(frozenTotal, now.timeIntervalSince(countingSince))
    }

    // MARK: Sous-questions

    /// « 3/9 », ou `nil` quand la cible n'a pas de sous-questions.
    ///
    /// Une cible qui n'a qu'une seule case n'en affiche pas : « 0/1 » n'apprend
    /// rien que le bouton « fait » ne dise déjà.
    var questionsLabel: String? {
        guard let total = questionsTotal, total > 1 else { return nil }
        return "\(min(questionsDone ?? 0, total))/\(total)"
    }

    /// Reste-t-il une sous-question à cocher ? C'est la condition du bouton.
    var hasNextQuestion: Bool {
        guard let total = questionsTotal, total > 0 else { return false }
        return (questionsDone ?? 0) < total
    }

    /// Part des sous-questions faites, pour la barre de l'écran verrouillé.
    var questionsProgress: Double? {
        guard let total = questionsTotal, total > 0 else { return nil }
        return min(1, max(0, Double(questionsDone ?? 0) / Double(total)))
    }
}

/// Le bloc Pomodoro en cours, tel que l'îlot peut le dessiner **seul**.
///
/// L'anneau ne reçoit pas une fraction rafraîchie chaque seconde : il reçoit les
/// deux bornes du bloc en horloge murale, et `ProgressView(timerInterval:)` le
/// remplit tout seul, comme `Text(timerInterval:)` fait avancer le compteur. Une
/// mise à jour par seconde coûterait de la batterie pour un résultat identique.
///
/// Les bornes sont en horloge murale alors que le chrono compte le **travail** :
/// c'est correct tant que le chrono tourne, et c'est précisément pourquoi elles
/// sont `nil` en pause — pendant une pause, le bloc n'avance pas, et un anneau
/// qui continuerait de se remplir mentirait. La pause garde donc `frozenProgress`.
struct ActivityPomodoro: Codable, Hashable {
    /// Bloc en cours, à partir de 1.
    var blockNumber: Int
    /// Blocs entièrement terminés dans la session.
    var completedBlocks: Int
    /// Début du bloc en cours, en horloge murale. `nil` en pause.
    var startedAt: Date?
    /// Fin prévue du bloc, en horloge murale. `nil` en pause.
    var endsAt: Date?
    /// Part du bloc déjà faite, figée — ce qu'on montre en pause.
    var frozenProgress: Double

    init(blockNumber: Int,
         completedBlocks: Int,
         startedAt: Date?,
         endsAt: Date?,
         frozenProgress: Double) {
        self.blockNumber = blockNumber
        self.completedBlocks = completedBlocks
        self.startedAt = startedAt
        self.endsAt = endsAt
        self.frozenProgress = frozenProgress
    }

    /// Projette l'avancement d'un bloc sur l'horloge murale.
    ///
    /// Les nombres viennent de `PomodoroEngine`, qui reste la seule autorité sur
    /// le découpage en blocs ; ce type ne fait que les traduire en dates, parce
    /// que c'est la seule forme qu'une Live Activity sait animer sans l'app.
    ///
    /// - Parameters:
    ///   - blockNumber: le bloc en cours, à partir de 1.
    ///   - elapsedInBlock: temps de travail déjà fait dans ce bloc.
    ///   - remaining: temps de travail restant avant la pause conseillée.
    ///   - completedBlocks: blocs entièrement terminés.
    ///   - running: le chrono tourne-t-il ?
    ///   - now: l'instant de référence, injectable pour les tests.
    static func make(blockNumber: Int,
                     elapsedInBlock: TimeInterval,
                     remaining: TimeInterval,
                     completedBlocks: Int,
                     running: Bool,
                     now: Date = Date()) -> ActivityPomodoro {
        let done = max(0, elapsedInBlock)
        let left = max(0, remaining)
        let total = done + left
        let progress = total > 0 ? min(1, done / total) : 1
        // Les bornes n'existent que s'il reste quelque chose à animer : en pause,
        // et sur un bloc arrivé à terme, l'anneau est **figé**, et c'est
        // `frozenProgress` qui le dessine.
        let animating = running && left > 0
        return ActivityPomodoro(blockNumber: max(1, blockNumber),
                                completedBlocks: max(0, completedBlocks),
                                startedAt: animating ? now.addingTimeInterval(-done) : nil,
                                endsAt: animating ? now.addingTimeInterval(left) : nil,
                                frozenProgress: progress)
    }

    /// L'intervalle que l'anneau doit animer, quand il y a lieu de l'animer.
    ///
    /// `nil` en pause, et `nil` sur un bloc déjà terminé : un intervalle vide ou
    /// inversé ferait dessiner un anneau plein d'un coup, ou rien du tout.
    var interval: ClosedRange<Date>? {
        guard let startedAt, let endsAt, endsAt > startedAt else { return nil }
        return startedAt...endsAt
    }

    /// Le bloc est fini : c'est le moment de proposer la pause.
    var isBlockComplete: Bool { frozenProgress >= 1 }

    /// « Bloc 3 ».
    var label: String { "Bloc \(blockNumber)" }
}
