import Foundation

/// Local, offline classifier that flags sensitive content in OCR'd text lines so
/// the editor can redact it in one click. No network, no model download: every
/// detector is a regex or a small heuristic that runs on the strings Vision
/// already recognized.
///
/// The bar for a match is deliberately high: a bare 4-digit group is not a card,
/// the word "token" with no value attached marks nothing. False positives waste
/// the user's screenshot, so each detector validates structure (Luhn for cards,
/// length + entropy for opaque secrets, key prefixes for provider tokens) before
/// it claims a region.
///
/// The classifier is pure and synchronous: it owns no Vision, no canvas geometry
/// and no UI. Callers feed it `[Line]` (recognized text + a box in IMAGE pixel
/// space) and get back `[Finding]` carrying the boxes that should be covered.
enum SecretClassifier {

    /// What kind of secret a finding covers. Drives the small category label the
    /// redaction preview shows over each box.
    enum Category: String, CaseIterable {
        case email
        case phone
        case cpf
        case cnpj
        case creditCard
        case iban
        case awsKey
        case githubToken
        case openAIKey
        case anthropicKey
        case slackToken
        case jwt
        case privateKey
        case highEntropySecret
        case passwordInContext

        /// Short, human label drawn on the preview chip. English copy.
        var label: String {
            switch self {
            case .email:              return "Email"
            case .phone:              return "Phone"
            case .cpf:                return "CPF"
            case .cnpj:               return "CNPJ"
            case .creditCard:         return "Card"
            case .iban:               return "IBAN"
            case .awsKey:             return "AWS key"
            case .githubToken:        return "GitHub token"
            case .openAIKey:          return "OpenAI key"
            case .anthropicKey:       return "Anthropic key"
            case .slackToken:         return "Slack token"
            case .jwt:                return "JWT"
            case .privateKey:         return "Private key"
            case .highEntropySecret:  return "Secret"
            case .passwordInContext:  return "Password"
            }
        }
    }

    /// One recognized text line. `box` is in IMAGE pixel coordinates (top-left
    /// origin); the classifier never touches it beyond carrying it through to the
    /// matching findings, so the caller stays in charge of all geometry.
    struct Line {
        let text: String
        let box: CGRect

        init(text: String, box: CGRect) {
            self.text = text
            self.box = box
        }
    }

    /// One sensitive hit. `text` is truncated for display/logging (the classifier
    /// is local, but a finding is never the place to echo a full secret). `boxes`
    /// are the image-space rects to redact, one per line the match spans.
    struct Finding {
        let category: Category
        let text: String
        let boxes: [CGRect]
    }

    /// Classify a set of recognized lines. Returns one finding per detected
    /// secret. A single line can yield several findings (e.g. an email and a
    /// phone on the same row); each finding owns the box of the line it came from.
    static func classify(lines: [Line]) -> [Finding] {
        var findings: [Finding] = []
        for line in lines {
            findings.append(contentsOf: detect(in: line))
        }
        return findings
    }

    // MARK: - Per-line detection

    private static func detect(in line: Line) -> [Finding] {
        let text = line.text
        guard !text.isEmpty else { return [] }
        var out: [Finding] = []

        // Provider tokens and structural secrets first: they are the most specific
        // and a hit here means the whole line is sensitive, so we never want a
        // weaker detector to also claim the same row.
        if let cat = providerOrStructuralCategory(in: text) {
            out.append(Finding(category: cat, text: truncate(matchedSecret(in: text) ?? text), boxes: [line.box]))
            return out
        }

        // password/secret in context: "password: hunter2", "senha = abc". The
        // value has to actually be there; a lone "password" label marks nothing.
        if passwordInContext(text) {
            out.append(Finding(category: .passwordInContext, text: truncate(text), boxes: [line.box]))
            return out
        }

        // Identity / contact / financial detectors. These can legitimately
        // co-occur on one line, so collect all that fire.
        for match in firstMatches(in: text, [
            (.creditCard, Self.creditCardPattern),
            (.iban, Self.ibanPattern),
            (.cnpj, Self.cnpjPattern),
            (.cpf, Self.cpfPattern),
            (.email, Self.emailPattern),
            (.phone, Self.phonePattern),
        ]) {
            out.append(Finding(category: match.category, text: truncate(match.matched), boxes: [line.box]))
        }

        // High-entropy opaque blob with no recognizable prefix (random API keys,
        // session tokens). Only when nothing more specific matched, so a base64
        // chunk of an email/JWT does not double-report.
        if out.isEmpty, let blob = highEntropyMatch(in: text) {
            out.append(Finding(category: .highEntropySecret, text: truncate(blob), boxes: [line.box]))
        }

        return out
    }

    // MARK: - Provider tokens and structural secrets

    /// Tokens with a fixed, unmistakable shape: provider key prefixes, JWTs and
    /// PEM private-key headers. A prefix match here is conclusive on its own.
    private static func providerOrStructuralCategory(in text: String) -> Category? {
        if regexMatches(privateKeyPattern, text) { return .privateKey }
        if regexMatches(awsKeyPattern, text) { return .awsKey }
        if regexMatches(githubTokenPattern, text) { return .githubToken }
        if regexMatches(anthropicKeyPattern, text) { return .anthropicKey }
        if regexMatches(openAIKeyPattern, text) { return .openAIKey }
        if regexMatches(slackTokenPattern, text) { return .slackToken }
        if regexMatches(jwtPattern, text) { return .jwt }
        return nil
    }

    /// Pulls the specific provider/JWT/key substring out of a line for display,
    /// so the truncated text shows the secret, not the surrounding prose.
    private static func matchedSecret(in text: String) -> String? {
        for pattern in [privateKeyPattern, awsKeyPattern, githubTokenPattern,
                        anthropicKeyPattern, openAIKeyPattern, slackTokenPattern, jwtPattern] {
            if let m = firstMatchString(pattern, text) { return m }
        }
        return nil
    }

    // MARK: - Password in context

    /// True when the line names a credential (password/senha/secret/token/apikey)
    /// AND carries an actual value after a separator. "password:" alone is a
    /// label, not a leak; "password: hunter2" is.
    private static let passwordContextPattern = try! NSRegularExpression(
        // key word, optional spaces, a : or = separator, then a value of >= 4
        // non-space chars. Anchored to a word boundary so "passwordless" or a
        // column header "Token" with nothing after it does not trip it.
        pattern: #"(?i)\b(password|passwd|pwd|senha|secret|token|api[\s_-]?key)\b\s*[:=]\s*\S{4,}"#
    )

    private static func passwordInContext(_ text: String) -> Bool {
        passwordContextPattern.firstMatch(in: text, range: fullRange(text)) != nil
    }

    // MARK: - Credit card (Luhn-checked)

    /// Matches a 13-19 digit run (optionally split by spaces/dashes in groups)
    /// and only reports it when the digits pass the Luhn checksum. This is what
    /// keeps a long order number or a phone string from being flagged as a card.
    private static let creditCardPattern = regex(#"\b(?:\d[ -]?){13,19}\b"#)

    private static func firstCreditCard(in text: String) -> String? {
        let matches = creditCardPattern.matches(in: text, range: fullRange(text))
        for m in matches {
            guard let range = Range(m.range, in: text) else { continue }
            let candidate = String(text[range])
            let digits = candidate.filter(\.isNumber)
            if digits.count >= 13, digits.count <= 19, luhnValid(digits) {
                return candidate
            }
        }
        return nil
    }

    /// Standard Luhn (mod 10) check over the card digits.
    private static func luhnValid(_ digits: String) -> Bool {
        guard !digits.isEmpty else { return false }
        var sum = 0
        var alternate = false
        for char in digits.reversed() {
            guard let d = char.wholeNumberValue else { return false }
            var value = d
            if alternate {
                value *= 2
                if value > 9 { value -= 9 }
            }
            sum += value
            alternate.toggle()
        }
        return sum % 10 == 0
    }

    // MARK: - CPF / CNPJ (Brazilian documents)

    /// CPF: 11 digits, masked (000.000.000-00) or bare. Validated by the two
    /// check digits so a random 11-digit run is not flagged.
    private static let cpfPattern = regex(#"\b\d{3}\.?\d{3}\.?\d{3}-?\d{2}\b"#)

    /// CNPJ: 14 digits, masked (00.000.000/0000-00) or bare, check-digit
    /// validated.
    private static let cnpjPattern = regex(#"\b\d{2}\.?\d{3}\.?\d{3}/?\d{4}-?\d{2}\b"#)

    private static func validCPF(_ raw: String) -> Bool {
        let digits = raw.filter(\.isNumber)
        guard digits.count == 11 else { return false }
        let nums = digits.compactMap(\.wholeNumberValue)
        // Reject all-equal sequences (000.. / 111..), which match the shape but
        // are never real documents.
        if Set(nums).count == 1 { return false }
        func checkDigit(upTo count: Int, startWeight: Int) -> Int {
            var sum = 0
            var weight = startWeight
            for i in 0..<count {
                sum += nums[i] * weight
                weight -= 1
            }
            let mod = (sum * 10) % 11
            return mod == 10 ? 0 : mod
        }
        return checkDigit(upTo: 9, startWeight: 10) == nums[9]
            && checkDigit(upTo: 10, startWeight: 11) == nums[10]
    }

    private static func validCNPJ(_ raw: String) -> Bool {
        let digits = raw.filter(\.isNumber)
        guard digits.count == 14 else { return false }
        let nums = digits.compactMap(\.wholeNumberValue)
        if Set(nums).count == 1 { return false }
        func checkDigit(weights: [Int]) -> Int {
            var sum = 0
            for (i, w) in weights.enumerated() { sum += nums[i] * w }
            let mod = sum % 11
            return mod < 2 ? 0 : 11 - mod
        }
        let first = checkDigit(weights: [5, 4, 3, 2, 9, 8, 7, 6, 5, 4, 3, 2])
        let second = checkDigit(weights: [6, 5, 4, 3, 2, 9, 8, 7, 6, 5, 4, 3, 2])
        return first == nums[12] && second == nums[13]
    }

    // MARK: - Email / phone / IBAN

    private static let emailPattern = regex(#"\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b"#, caseInsensitive: true)

    /// Phone, BR and international. Demands a strong signal so a bare digit run
    /// (an order id, a card that failed Luhn) is never flagged: either a leading
    /// + country code, or a parenthesized DDD. Examples that match: (11) 91234-5678,
    /// +55 11 91234 5678, +1 415 555 2671. Examples that do not: 1234567,
    /// 1234 5678 9012 3456.
    private static let phonePattern = regex(#"(?:\+\d{1,3}[\s.-]?(?:\(?\d{2,4}\)?[\s.-]?)?|\(\d{2,4}\)[\s.-]?)\d{3,5}[\s.-]?\d{4}\b"#)

    /// IBAN: 2-letter country, 2 check digits, then 11-30 alnum. Spaces allowed
    /// in groups of four.
    private static let ibanPattern = regex(#"\b[A-Z]{2}\d{2}(?:[ ]?[A-Z0-9]{4}){2,7}(?:[ ]?[A-Z0-9]{1,3})?\b"#)

    // MARK: - Provider key / JWT / PEM patterns

    private static let awsKeyPattern = regex(#"\b(AKIA|ASIA|AGPA|AIDA|AROA|ANPA|ANVA)[0-9A-Z]{16}\b"#)
    private static let githubTokenPattern = regex(#"\b(ghp|gho|ghu|ghs|ghr)_[0-9A-Za-z]{36,}\b|\bgithub_pat_[0-9A-Za-z_]{22,}\b"#)
    private static let openAIKeyPattern = regex(#"\bsk-(?!ant-)[0-9A-Za-z_-]{20,}\b"#)
    private static let anthropicKeyPattern = regex(#"\bsk-ant-[0-9A-Za-z_-]{20,}\b"#)
    private static let slackTokenPattern = regex(#"\bxox[baprs]-[0-9A-Za-z-]{10,}\b"#)
    private static let jwtPattern = regex(#"\beyJ[0-9A-Za-z_-]{8,}\.[0-9A-Za-z_-]{8,}\.[0-9A-Za-z_-]{8,}\b"#)
    private static let privateKeyPattern = regex(#"-----BEGIN (?:RSA |EC |DSA |OPENSSH |PGP )?PRIVATE KEY-----"#)

    // MARK: - High-entropy opaque secret

    private static let highEntropyPattern = regex(#"[A-Za-z0-9+/=_-]{25,}"#)

    /// A long opaque blob (hex or base64) with high Shannon entropy and no
    /// recognizable structure. Catches random API keys / session tokens that
    /// carry no provider prefix. Width > 24 chars and entropy > 4.5 bits/char,
    /// per the brief, so ordinary words and short codes stay clear.
    private static func highEntropyMatch(in text: String) -> String? {
        let matches = highEntropyPattern.matches(in: text, range: fullRange(text))
        for m in matches {
            guard let range = Range(m.range, in: text) else { continue }
            let candidate = String(text[range])
            guard candidate.count > 24 else { continue }
            // Require a mix of letter and digit so a long run of one alphabet
            // (e.g. a repeated word) does not clear the bar on entropy alone.
            let hasLetter = candidate.contains(where: { $0.isLetter })
            let hasDigit = candidate.contains(where: { $0.isNumber })
            guard hasLetter, hasDigit else { continue }
            if shannonEntropy(candidate) > 4.5 { return candidate }
        }
        return nil
    }

    /// Shannon entropy in bits per character.
    private static func shannonEntropy(_ string: String) -> Double {
        guard !string.isEmpty else { return 0 }
        var counts: [Character: Int] = [:]
        for ch in string { counts[ch, default: 0] += 1 }
        let length = Double(string.count)
        var entropy = 0.0
        for count in counts.values {
            let p = Double(count) / length
            entropy -= p * log2(p)
        }
        return entropy
    }

    // MARK: - Matching helpers

    private struct PatternHit {
        let category: Category
        let matched: String
    }

    /// Runs a prioritized list of (category, pattern) and returns one hit per
    /// category that fires. CPF/CNPJ/card go through their validators; the rest
    /// report the first regex match. Order matters: card before CPF before phone,
    /// so the strongest structural claim on overlapping digit runs wins and the
    /// weaker ones are skipped for that span.
    private static func firstMatches(in text: String, _ specs: [(Category, NSRegularExpression)]) -> [PatternHit] {
        var hits: [PatternHit] = []
        var consumedRanges: [Range<String.Index>] = []

        for (category, pattern) in specs {
            let candidate: String?
            switch category {
            case .creditCard:
                candidate = firstCreditCard(in: text)
            case .cpf:
                candidate = firstValidated(pattern, in: text, validate: validCPF)
            case .cnpj:
                candidate = firstValidated(pattern, in: text, validate: validCNPJ)
            default:
                candidate = firstMatchString(pattern, text, avoiding: consumedRanges)
            }
            guard let matched = candidate, !matched.isEmpty else { continue }
            // Record the matched span so a later, weaker detector does not also
            // grab the same digits (a card number must not re-report as a phone).
            if let r = text.range(of: matched) { consumedRanges.append(r) }
            hits.append(PatternHit(category: category, matched: matched))
        }
        return hits
    }

    private static func firstValidated(_ pattern: NSRegularExpression, in text: String, validate: (String) -> Bool) -> String? {
        let matches = pattern.matches(in: text, range: fullRange(text))
        for m in matches {
            guard let range = Range(m.range, in: text) else { continue }
            let candidate = String(text[range])
            if validate(candidate) { return candidate }
        }
        return nil
    }

    private static func firstMatchString(_ pattern: NSRegularExpression, _ text: String, avoiding consumed: [Range<String.Index>] = []) -> String? {
        let matches = pattern.matches(in: text, range: fullRange(text))
        for m in matches {
            guard let range = Range(m.range, in: text) else { continue }
            if consumed.contains(where: { $0.overlaps(range) }) { continue }
            return String(text[range])
        }
        return nil
    }

    private static func regexMatches(_ pattern: NSRegularExpression, _ text: String) -> Bool {
        pattern.firstMatch(in: text, range: fullRange(text)) != nil
    }

    private static func fullRange(_ text: String) -> NSRange {
        NSRange(text.startIndex..., in: text)
    }

    private static func regex(_ pattern: String, caseInsensitive: Bool = false) -> NSRegularExpression {
        let options: NSRegularExpression.Options = caseInsensitive ? [.caseInsensitive] : []
        // Patterns here are compile-time literals; a failure is a programmer error,
        // not a runtime condition, so a trap is the honest signal.
        return try! NSRegularExpression(pattern: pattern, options: options)
    }

    /// Truncate a secret for display so the preview chip and any logging never
    /// echo the whole thing. Keeps a short head, masks the rest.
    private static func truncate(_ text: String, head: Int = 6) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > head + 3 else { return trimmed }
        let prefix = trimmed.prefix(head)
        return "\(prefix)\u{2026} (\(trimmed.count) chars)"
    }
}
