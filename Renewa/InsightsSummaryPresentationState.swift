import Foundation

struct InsightsSummaryPresentationState: Equatable {
    enum Source: Equatable {
        case ai(isCached: Bool)
        case deterministic
    }

    /// What the view needs to know about a subscription an insight points at, resolved by the
    /// store so this type stays free of currency plumbing.
    struct SubscriptionFacts: Equatable {
        let id: UUID
        let name: String
        let cadenceLabel: String
        /// Monthly cost in the display currency, or `nil` when no rate was available.
        let monthlyCost: Decimal?

        init(id: UUID, name: String, cadenceLabel: String, monthlyCost: Decimal?) {
            self.id = id
            self.name = name
            self.cadenceLabel = cadenceLabel
            self.monthlyCost = monthlyCost
        }
    }

    /// A stretch of summary prose. Figures are pulled out so they can be set in the serif face and
    /// read as data rather than as words.
    struct Run: Equatable, Identifiable {
        let id: Int
        let text: String
        let isFigure: Bool
    }

    /// A styled piece of a word. A word can straddle a run boundary — “$9.99/mo” is a figure
    /// followed by plain text — so the pieces have to stay together when the line wraps.
    struct Fragment: Equatable, Identifiable {
        let id: Int
        let text: String
        let isFigure: Bool
    }

    struct Word: Equatable, Identifiable {
        let id: Int
        let fragments: [Fragment]
    }

    struct Paragraph: Equatable, Identifiable {
        let id: Int
        /// The opening paragraph carries the larger serif voice.
        let isLead: Bool
        let runs: [Run]

        var plainText: String { runs.map(\.text).joined() }

        /// The paragraph broken at whitespace, so each word can be laid out — and animated — alone.
        var words: [Word] {
            var words: [Word] = []
            var fragments: [Fragment] = []

            func flushWord() {
                guard !fragments.isEmpty else { return }
                words.append(Word(id: words.count, fragments: fragments))
                fragments = []
            }

            for run in runs {
                var pending = ""

                func flushFragment() {
                    guard !pending.isEmpty else { return }
                    fragments.append(Fragment(id: fragments.count, text: pending, isFigure: run.isFigure))
                    pending = ""
                }

                for character in run.text {
                    if character.isWhitespace {
                        flushFragment()
                        flushWord()
                    } else {
                        pending.append(character)
                    }
                }
                flushFragment()
            }

            flushWord()
            return words
        }
    }

    struct DetailRow: Equatable, Identifiable {
        let id: Int
        let label: String
        let valueText: String
        let isEmphasis: Bool
    }

    /// One card from the report, presented as something worth a second look.
    struct Finding: Equatable, Identifiable {
        let id: String
        let title: String
        let body: String
        /// The one-line preview shown under the title in the list.
        let meta: String
        let rows: [DetailRow]
    }

    let source: Source
    let generatedAt: Date
    let evidence: InsightEvidenceSummary?
    let paragraphs: [Paragraph]
    let findings: [Finding]

    init(
        report: InsightReport,
        subscriptions: [SubscriptionFacts] = [],
        displayCurrency: String = "USD"
    ) {
        generatedAt = report.provenance?.generatedAt ?? report.generatedAt
        evidence = report.provenance?.evidence

        switch report.provenance?.source {
        case .ai:
            source = .ai(isCached: report.provenance?.isCached ?? false)
        case .deterministic:
            source = .deterministic
        case nil:
            source = report.isAIGenerated ? .ai(isCached: false) : .deterministic
        }

        paragraphs = Self.paragraphs(from: report.summary)
        findings = Self.findings(
            from: report.cards,
            subscriptions: subscriptions,
            displayCurrency: displayCurrency
        )
    }

    var title: String {
        switch source {
        case .ai:
            "Renewa’s read"
        case .deterministic:
            "Basic subscription summary"
        }
    }

    var sourceLabel: String {
        switch source {
        case .ai(isCached: true):
            "AI-generated · Cached"
        case .ai(isCached: false):
            "AI-generated"
        case .deterministic:
            "Basic subscription summary"
        }
    }

    var isAIDegraded: Bool {
        if case .deterministic = source { return true }
        return false
    }

    /// Trailing value beside the “Worth a look” heading.
    var findingsLabel: String? {
        findings.isEmpty ? nil : "\(findings.count) to review"
    }

    var evidenceLabel: String? {
        guard let evidence else { return nil }
        var parts: [String] = []
        if evidence.activeSubscriptionCount > 0 {
            parts.append("\(evidence.activeSubscriptionCount) active \(noun(evidence.activeSubscriptionCount, singular: "subscription"))")
        }
        if evidence.billingEventCount > 0 {
            parts.append("\(evidence.billingEventCount) billing \(noun(evidence.billingEventCount, singular: "event"))")
        }
        if evidence.monthlySnapshotCount > 0 {
            parts.append("\(evidence.monthlySnapshotCount) monthly \(noun(evidence.monthlySnapshotCount, singular: "snapshot"))")
        }
        guard !parts.isEmpty else { return nil }
        return "Based on " + naturalLanguageList(parts)
    }

    private func noun(_ count: Int, singular: String) -> String {
        count == 1 ? singular : "\(singular)s"
    }

    private func naturalLanguageList(_ values: [String]) -> String {
        switch values.count {
        case 0:
            ""
        case 1:
            values[0]
        case 2:
            values.joined(separator: " and ")
        default:
            "\(values.dropLast().joined(separator: ", ")), and \(values.last ?? "")"
        }
    }

    // MARK: - Prose

    private static func paragraphs(from summary: String) -> [Paragraph] {
        let blocks =
            summary
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        let texts: [String]
        if blocks.count > 1 {
            texts = blocks
        } else if let single = blocks.first {
            texts = leadAndRest(of: single)
        } else {
            texts = []
        }

        return texts.enumerated().map { index, text in
            Paragraph(id: index, isLead: index == 0, runs: runs(in: text))
        }
    }

    /// A single block reads better as a serif opening line followed by the detail behind it.
    private static func leadAndRest(of text: String) -> [String] {
        guard let breakIndex = sentenceBreak(in: text) else { return [text] }
        let lead = String(text[text.startIndex..<breakIndex]).trimmingCharacters(in: .whitespaces)
        let rest = String(text[breakIndex...]).trimmingCharacters(in: .whitespaces)
        return rest.isEmpty ? [lead] : [lead, rest]
    }

    /// A second paragraph shorter than this is a fragment, not a paragraph.
    private static let minimumTrailingParagraph = 24

    private static func sentenceBreak(in text: String) -> String.Index? {
        var index = text.startIndex
        while index < text.endIndex {
            defer { index = text.index(after: index) }
            guard text[index] == "." || text[index] == "!" || text[index] == "?" else { continue }

            let next = text.index(after: index)
            guard next < text.endIndex, text[next].isWhitespace else { continue }
            guard text.distance(from: next, to: text.endIndex) >= minimumTrailingParagraph else {
                return nil
            }
            return next
        }
        return nil
    }

    private static let currencySymbols: Set<Character> = ["$", "€", "£", "₸", "¥", "₹", "₩"]

    private static func runs(in text: String) -> [Run] {
        var runs: [Run] = []
        var plain = ""
        var index = text.startIndex

        func flushPlain() {
            guard !plain.isEmpty else { return }
            runs.append(Run(id: runs.count, text: plain, isFigure: false))
            plain = ""
        }

        while index < text.endIndex {
            guard currencySymbols.contains(text[index]),
                let end = figureEnd(in: text, from: index)
            else {
                plain.append(text[index])
                index = text.index(after: index)
                continue
            }
            flushPlain()
            runs.append(Run(id: runs.count, text: String(text[index..<end]), isFigure: true))
            index = end
        }

        flushPlain()
        return runs
    }

    /// End of the amount that starts at `start`, or `nil` when the symbol is not followed by one.
    private static func figureEnd(in text: String, from start: String.Index) -> String.Index? {
        var index = text.index(after: start)
        if index < text.endIndex, text[index] == " " || text[index] == "\u{00A0}" {
            index = text.index(after: index)
        }
        guard index < text.endIndex, text[index].isNumber else { return nil }

        var end = index
        while end < text.endIndex {
            let character = text[end]
            let next = text.index(after: end)
            if character.isNumber || character == "," {
                end = next
            } else if character == ".", next < text.endIndex, text[next].isNumber {
                end = next
            } else {
                break
            }
        }
        return end
    }

    // MARK: - Findings

    private static func findings(
        from cards: [InsightCard],
        subscriptions: [SubscriptionFacts],
        displayCurrency: String
    ) -> [Finding] {
        let byID = Dictionary(subscriptions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        return cards.map { card in
            let referenced = card.subscriptionIDs
                .compactMap(UUID.init(uuidString:))
                .compactMap { byID[$0] }

            return Finding(
                id: card.id,
                title: card.title,
                body: card.body,
                meta: firstSentence(of: card.body),
                rows: detailRows(for: referenced, displayCurrency: displayCurrency)
            )
        }
    }

    private static func detailRows(
        for subscriptions: [SubscriptionFacts],
        displayCurrency: String
    ) -> [DetailRow] {
        var rows = subscriptions.enumerated().map { index, subscription in
            DetailRow(
                id: index,
                label: "\(subscription.name) · \(subscription.cadenceLabel)",
                valueText: subscription.monthlyCost?.currencyText(code: displayCurrency) ?? "—",
                isEmphasis: false
            )
        }

        let known = subscriptions.compactMap(\.monthlyCost)
        if rows.count > 1, known.count > 1 {
            rows.append(
                DetailRow(
                    id: rows.count,
                    label: "Together, every month",
                    valueText: known.reduce(Decimal.zero, +).currencyText(code: displayCurrency),
                    isEmphasis: true
                )
            )
        }
        return rows
    }

    private static func firstSentence(of text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let breakIndex = sentenceBreak(in: trimmed) else { return trimmed }
        return String(trimmed[trimmed.startIndex..<breakIndex]).trimmingCharacters(in: .whitespaces)
    }
}
