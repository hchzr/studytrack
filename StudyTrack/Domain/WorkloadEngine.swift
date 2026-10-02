import Foundation

/// Différence entre le temps attendu par l'EPFL et le temps réellement effectué.
struct WorkloadDelta: Equatable {
    var expectedSeconds: Int = 0
    var actualSeconds: Int = 0
    var classSeconds: Int = 0
    /// Part « cours » du temps attendu (heures de présence en amphi).
    var lectureSeconds: Int = 0
    /// Part « exercices / travail personnel » du temps attendu.
    var exerciseSeconds: Int = 0

    /// Réel − attendu (négatif = en retard sur la charge EPFL).
    var deltaSeconds: Int { actualSeconds - expectedSeconds }

    var expectedHours: Double { Double(expectedSeconds) / 3600 }
    var actualHours: Double { Double(actualSeconds) / 3600 }
    var deltaHours: Double { Double(deltaSeconds) / 3600 }

    /// Ratio réel / attendu (1.0 = pile dans les temps).
    var completion: Double {
        expectedSeconds <= 0 ? 0 : Double(actualSeconds) / Double(expectedSeconds)
    }

    var isOnTrack: Bool { completion >= 0.9 }
    var isBehind: Bool { completion < 0.75 }

    var deltaLabel: String {
        let sign = deltaSeconds >= 0 ? "+" : "−"
        return "\(sign)\(DateUtils.hoursLabel(seconds: abs(deltaSeconds)))"
    }

    var expectedLabel: String { DateUtils.hoursLabel(seconds: expectedSeconds) }
    var actualLabel: String { DateUtils.hoursLabel(seconds: actualSeconds) }
    var classLabel: String { DateUtils.hoursLabel(seconds: classSeconds) }
}

/// Moteur de charge de travail EPFL (fonctions pures).
///
/// Modèle : charge totale attendue = `crédits × heuresParCrédit`.
/// La part « cours » correspond aux heures d'amphi planifiées sur le semestre ;
/// le reste est le travail personnel (exercices, révisions, vidéos…).
enum WorkloadEngine {

    // MARK: Attendu

    static func totalWeeks(for course: Course) -> Int {
        max(course.term?.totalWeeks ?? 14, 1)
    }

    /// Charge totale attendue sur tout le semestre (secondes).
    static func expectedTotalSeconds(for course: Course, hoursPerCredit: Double) -> Int {
        Int((course.credits * hoursPerCredit * 3600).rounded())
    }

    /// Part « amphi » attendue sur le semestre.
    ///
    /// Vaut **zéro** pour un cours sans heures de cours magistral : c'est ce qui
    /// permet de répondre honnêtement à « choisir les classes qui ont cours ».
    static func expectedLectureSeconds(for course: Course) -> Int {
        guard course.hasLectures else { return 0 }
        return Int((course.weeklyLectureHours * Double(totalWeeks(for: course)) * 3600).rounded())
    }

    /// Charge attendue bornée à `weeks` semaines écoulées / à venir.
    static func expectedSeconds(for course: Course,
                                hoursPerCredit: Double,
                                weeks: Int) -> (total: Int, lecture: Int, exercise: Int) {
        let total = expectedTotalSeconds(for: course, hoursPerCredit: hoursPerCredit)
        let allWeeks = totalWeeks(for: course)
        let clampedWeeks = max(0, min(weeks, allWeeks))
        let fraction = Double(clampedWeeks) / Double(allWeeks)
        let proportional = Int((Double(total) * fraction).rounded())
        let weeklyLecture = course.hasLectures ? course.weeklyLectureHours : 0
        let lecture = Int((weeklyLecture * Double(clampedWeeks) * 3600).rounded())
        return (proportional, lecture, max(0, proportional - lecture))
    }

    // MARK: Attendu hebdomadaire

    /// Heures de travail **personnel** attendues par semaine pour ce cours.
    ///
    /// Déduit de la charge ECTS quand l'étudiant·e n'a rien fixé : ce qui reste
    /// une fois les heures encadrées retirées. Un cours de 6 ECTS à 30 h/crédit
    /// sur 14 semaines vaut ~12,9 h/semaine ; avec 3 h d'amphi et 2 h d'exos, il
    /// reste ~7,9 h de travail personnel.
    static func weeklySelfStudyHours(for course: Course, hoursPerCredit: Double) -> Double {
        if let explicit = course.weeklySelfStudyHours { return max(0, explicit) }
        let implied = course.credits * hoursPerCredit / Double(totalWeeks(for: course))
        return max(0, implied - framedWeeklyHours(for: course))
    }

    /// Heures **encadrées** par semaine : amphi (si le cours en a) + séances d'exos.
    static func framedWeeklyHours(for course: Course) -> Double {
        (course.hasLectures ? course.weeklyLectureHours : 0) + course.weeklyExerciseHours
    }

    /// Charge attendue **pour une semaine** (secondes).
    static func expectedWeeklySeconds(for course: Course, hoursPerCredit: Double) -> Int {
        let total = framedWeeklyHours(for: course)
            + weeklySelfStudyHours(for: course, hoursPerCredit: hoursPerCredit)
        return Int((total * 3600).rounded())
    }

    /// Delta **hebdomadaire** : l'attendu d'une semaine comparé au réel de cette
    /// semaine-là.
    ///
    /// C'est la seule comparaison qui se traduise en action. « 120 h attendues sur
    /// le semestre » ne dit pas à l'étudiant·e s'il ou elle est en retard
    /// *maintenant*.
    static func weeklyDelta(for course: Course,
                            hoursPerCredit: Double,
                            from: Date,
                            to: Date) -> WorkloadDelta {
        var d = WorkloadDelta()
        let lecture = course.hasLectures ? course.weeklyLectureHours : 0
        d.expectedSeconds = expectedWeeklySeconds(for: course, hoursPerCredit: hoursPerCredit)
        d.lectureSeconds = Int((lecture * 3600).rounded())
        d.exerciseSeconds = max(0, d.expectedSeconds - d.lectureSeconds)
        let klass = classSeconds(for: course, from: from, to: to)
        d.classSeconds = klass
        d.actualSeconds = studySeconds(for: course, from: from, to: to) + klass
        return d
    }

    /// Agrégat hebdomadaire sur plusieurs cours.
    static func aggregateWeekly(courses: [Course],
                                hoursPerCredit: Double,
                                from: Date,
                                to: Date) -> WorkloadDelta {
        var total = WorkloadDelta()
        for course in courses {
            let d = weeklyDelta(for: course, hoursPerCredit: hoursPerCredit, from: from, to: to)
            total.expectedSeconds += d.expectedSeconds
            total.lectureSeconds += d.lectureSeconds
            total.exerciseSeconds += d.exerciseSeconds
            total.classSeconds += d.classSeconds
            total.actualSeconds += d.actualSeconds
        }
        return total
    }

    // MARK: Réel

    /// Temps de travail personnel enregistré sur le cours (secondes),
    /// éventuellement borné à une fenêtre.
    static func studySeconds(for course: Course, from: Date? = nil, to: Date? = nil) -> Int {
        course.sessions
            .filter { session in
                if let from, session.startedAt < from { return false }
                if let to, session.startedAt >= to { return false }
                return true
            }
            .reduce(0) { $0 + $1.durationSeconds }
    }

    /// Heures d'amphi suivies : les cours magistraux de l'horaire, finis et pas
    /// marqués manqués. Les séances d'exercices n'y entrent pas (chronométrées).
    ///
    /// La part d'un cours recouverte par un chrono du même cours n'est pas
    /// recomptée : elle est déjà dans `studySeconds` (`StudyTime`).
    static func classSeconds(for course: Course, from: Date? = nil, to: Date? = nil) -> Int {
        let events = course.linkedEvents.filter { event in
            if let from, event.startsAt < from { return false }
            if let to, event.startsAt >= to { return false }
            return true
        }
        return StudyTime.lectureBlocks(events: events, sessions: course.sessions).reduce(0) { $0 + $1.seconds }
    }

    // MARK: Delta

    /// Delta sur l'ensemble du semestre.
    static func delta(for course: Course, hoursPerCredit: Double) -> WorkloadDelta {
        delta(for: course, hoursPerCredit: hoursPerCredit, weeks: totalWeeks(for: course))
    }

    /// Delta borné à `weeks` semaines.
    static func delta(for course: Course, hoursPerCredit: Double, weeks: Int) -> WorkloadDelta {
        let expected = expectedSeconds(for: course, hoursPerCredit: hoursPerCredit, weeks: weeks)
        let study = studySeconds(for: course)
        let klass = classSeconds(for: course)
        var d = WorkloadDelta()
        d.expectedSeconds = expected.total
        d.lectureSeconds = expected.lecture
        d.exerciseSeconds = expected.exercise
        d.classSeconds = klass
        d.actualSeconds = study + klass
        return d
    }

    /// Delta borné à une fenêtre de dates (pour jour / semaine / mois).
    static func delta(for course: Course,
                      hoursPerCredit: Double,
                      from: Date?,
                      to: Date?) -> WorkloadDelta {
        // Proportion de semaines couvertes par la fenêtre.
        let start = from ?? course.term?.startDate ?? Date()
        let end = to ?? Date()
        let days = max(1, DateUtils.daysBetween(start, end))
        let weeks = max(1, Int((Double(days) / 7.0).rounded(.up)))
        let expected = expectedSeconds(for: course, hoursPerCredit: hoursPerCredit, weeks: weeks)
        let study = studySeconds(for: course, from: from, to: to)
        let klass = classSeconds(for: course, from: from, to: to)
        var d = WorkloadDelta()
        d.expectedSeconds = expected.total
        d.lectureSeconds = expected.lecture
        d.exerciseSeconds = expected.exercise
        d.classSeconds = klass
        d.actualSeconds = study + klass
        return d
    }

    /// Agrégat sur plusieurs cours.
    static func aggregate(courses: [Course], hoursPerCredit: Double) -> WorkloadDelta {
        var total = WorkloadDelta()
        for course in courses {
            let d = delta(for: course, hoursPerCredit: hoursPerCredit)
            total.expectedSeconds += d.expectedSeconds
            total.actualSeconds += d.actualSeconds
            total.classSeconds += d.classSeconds
            total.lectureSeconds += d.lectureSeconds
            total.exerciseSeconds += d.exerciseSeconds
        }
        return total
    }

    /// Agrégat sur une fenêtre temporelle.
    static func aggregate(courses: [Course],
                          hoursPerCredit: Double,
                          from: Date?,
                          to: Date?) -> WorkloadDelta {
        var total = WorkloadDelta()
        for course in courses {
            let d = delta(for: course, hoursPerCredit: hoursPerCredit, from: from, to: to)
            total.expectedSeconds += d.expectedSeconds
            total.actualSeconds += d.actualSeconds
            total.classSeconds += d.classSeconds
            total.lectureSeconds += d.lectureSeconds
            total.exerciseSeconds += d.exerciseSeconds
        }
        return total
    }

    /// Charge attendue « à ce stade du semestre » pour un cours.
    static func expectedToDate(for course: Course, hoursPerCredit: Double) -> WorkloadDelta {
        guard let term = course.term else {
            return delta(for: course, hoursPerCredit: hoursPerCredit)
        }
        let elapsed = DateUtils.weekNumber(for: Date(), term: term)
        return delta(for: course, hoursPerCredit: hoursPerCredit, weeks: elapsed)
    }
}
