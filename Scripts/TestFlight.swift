// Funston's TestFlight command line: builds, uploads and hands builds to
// testers through the App Store Connect API instead of the web page.
// Run it through Scripts/testflight, which compiles this file on first use.
import CryptoKit
import Foundation

@main
struct TestFlightCLI {
    static func main() async {
        var arguments = Array(CommandLine.arguments.dropFirst())
        let command = arguments.isEmpty ? "help" : arguments.removeFirst()
        do {
            switch command {
            case "builds": try await Commands.builds(Options(arguments))
            case "groups": try await Commands.groups()
            case "stats": try await Commands.stats(Options(arguments))
            case "distribute": try await Commands.distribute(Options(arguments))
            case "wait": try await Commands.wait(Options(arguments))
            case "ship": try await Commands.ship(Options(arguments))
            case "selftest": try Commands.selftest()
            case "setup": try Commands.setup()
            case "help", "-h", "--help": print(usage)
            default: throw CLIError.usage("Unknown command \"\(command)\".\n\n" + usage)
            }
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            exit(1)
        }
    }
}

let usage = """
Usage: Scripts/testflight <command>

  builds [--limit N]          Recent builds with their TestFlight states and groups.
  groups                      Beta groups and whether they're internal or external.
  stats [--limit N]           Invitations, installs, sessions, crashes and feedback per build,
      [--days 7|30|90|365]    then each tester's state, installed build, device and usage
                              over the last --days (default 365).
  distribute <build>          Add a processed build to tester groups, then submit it
      [--group NAME]...       for Beta App Review when any group is external.
      [--notes TEXT]          Defaults to the groups in ~/.appstoreconnect/funston.json,
      [--no-submit]           or "Public Beta".
  wait <build> [--minutes N]  Wait until App Store Connect finishes processing a build.
  ship [--group NAME]...      Bump the build number, archive, upload, wait for processing,
      [--notes TEXT]          then distribute. --carplay keeps the CarPlay entitlement,
      [--carplay]             which the developer account doesn't have yet.
      [--no-submit]           --dry-run prints the plan and changes nothing.
      [--dry-run]
  setup                       Check the API key configuration.
  selftest                    Check token signing with a throwaway key; no network.
"""

// MARK: - Errors and options

enum CLIError: Error, CustomStringConvertible {
    case usage(String)
    case notConfigured(String)
    case api(status: Int, detail: String)
    case notFound(String)
    case timedOut(String)
    case failed(String)

    var description: String {
        switch self {
        case .usage(let text), .notConfigured(let text), .notFound(let text), .timedOut(let text), .failed(let text): text
        case .api(let status, let detail): "App Store Connect answered \(status): \(detail)"
        }
    }
}

struct Options {
    var positional: [String] = []
    var values: [String: [String]] = [:]
    var flags: Set<String> = []
    static let valued: Set<String> = ["--group", "--notes", "--limit", "--minutes", "--days"]

    init(_ arguments: [String]) throws {
        var remaining = arguments[...]
        while let argument = remaining.popFirst() {
            if Self.valued.contains(argument) {
                guard let value = remaining.popFirst() else { throw CLIError.usage("\(argument) needs a value.") }
                values[argument, default: []].append(value)
            } else if argument.hasPrefix("--") {
                flags.insert(argument)
            } else {
                positional.append(argument)
            }
        }
    }

    func value(_ name: String) -> String? { values[name]?.last }
    func number(_ name: String, default fallback: Int) throws -> Int {
        guard let text = value(name) else { return fallback }
        guard let number = Int(text), number > 0 else { throw CLIError.usage("\(name) needs a positive number, not \"\(text)\".") }
        return number
    }
}

// MARK: - Configuration

struct Config {
    static let appID = "6820548872"
    /// Your Apple Developer team ID. The public repository leaves it blank, like DEVELOPMENT_TEAM in project.yml.
    static let teamID = ""
    static let directory = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".appstoreconnect")
    static let file = directory.appending(path: "funston.json")
    static let defaultGroups = ["Public Beta"]

    let keyID: String
    let issuerID: String
    let keyURL: URL
    let groups: [String]

    static let setupHelp = """
    App Store Connect API access isn't set up yet.

    1. In App Store Connect, open Users and Access > Integrations > App Store Connect API
       and generate a Team key with the App Manager role.
    2. Download the key (Apple only offers it once) and move it to
       ~/.appstoreconnect/private_keys/AuthKey_<KEY ID>.p8
    3. Save the two IDs from that page to ~/.appstoreconnect/funston.json:
       {"keyID": "<KEY ID>", "issuerID": "<ISSUER ID>"}

    The .p8 file is the secret. Keep it out of the repository.
    """

    /// Environment variables override the file, so a CI job can supply its own key.
    static func load() throws -> Config {
        let environment = ProcessInfo.processInfo.environment
        var stored: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: file.path) {
            let data = try Data(contentsOf: file)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw CLIError.notConfigured("\(file.path) must hold a JSON object.")
            }
            stored = object
        }
        guard let keyID = environment["ASC_KEY_ID"] ?? stored["keyID"] as? String,
              let issuerID = environment["ASC_ISSUER_ID"] ?? stored["issuerID"] as? String else {
            throw CLIError.notConfigured(setupHelp)
        }
        let keyURL = (environment["ASC_KEY_PATH"] ?? stored["keyPath"] as? String)
            .map { URL(filePath: NSString(string: $0).expandingTildeInPath) }
            ?? directory.appending(path: "private_keys/AuthKey_\(keyID).p8")
        guard FileManager.default.fileExists(atPath: keyURL.path) else {
            throw CLIError.notConfigured("No private key at \(keyURL.path).\n\n" + setupHelp)
        }
        return Config(keyID: keyID, issuerID: issuerID, keyURL: keyURL,
                      groups: stored["groups"] as? [String] ?? defaultGroups)
    }
}

// MARK: - Token

/// The App Store Connect API takes an ES256 JWT signed with the team's .p8 key.
enum Token {
    /// Apple rejects tokens that live longer than 20 minutes.
    static let lifetime = 15 * 60
    static let audience = "appstoreconnect-v1"

    static func make(keyID: String, issuerID: String, pem: String, now: Date = Date()) throws -> String {
        let key = try P256.Signing.PrivateKey(pemRepresentation: pem)
        let issued = Int(now.timeIntervalSince1970)
        let header: [String: Any] = ["alg": "ES256", "kid": keyID, "typ": "JWT"]
        let claims: [String: Any] = ["iss": issuerID, "iat": issued, "exp": issued + lifetime, "aud": audience]
        let signingInput = try encode(header) + "." + encode(claims)
        // JWS wants the raw 64-byte r||s form, not DER.
        let signature = try key.signature(for: Data(signingInput.utf8))
        return signingInput + "." + base64URL(signature.rawRepresentation)
    }

    static func encode(_ object: [String: Any]) throws -> String {
        base64URL(try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decode(_ segment: Substring) -> Data? {
        var text = segment.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        text += String(repeating: "=", count: (4 - text.count % 4) % 4)
        return Data(base64Encoded: text)
    }
}

// MARK: - API client

struct BuildInfo {
    let id: String
    let number: String
    let version: String
    let processing: String
    let uploaded: String
    let internalState: String
    let externalState: String
}

struct BetaGroup {
    let id: String
    let name: String
    let isInternal: Bool
    let publicLink: Bool
}

// MARK: - Usage

/// One window of TestFlight usage. Builds report invites and installs; testers don't.
struct Usage: Equatable {
    var start = ""
    var end = ""
    var invites: Int?
    var installs: Int?
    var sessions = 0
    var crashes = 0
    var feedback = 0
}

struct Tester: Equatable {
    let id: String
    let name: String
    let state: String
    let inviteType: String
    /// "0.2.0 (16)  iPhone17,5  iOS 27.0" for each device the tester installed on.
    let devices: [String]
}

/// Parses the App Store Connect responses `stats` reads. Pure, so selftest can feed it recorded payloads.
enum UsageParsing {
    /// Apple's metrics answer with dataPoints, one per window; a window with no
    /// activity can be missing entirely, which is zero usage rather than an error.
    static func usage(from entry: [String: Any]) -> Usage {
        var usage = Usage()
        for point in entry["dataPoints"] as? [[String: Any]] ?? [] {
            let values = point["values"] as? [String: Any] ?? [:]
            if usage.start.isEmpty || (point["start"] as? String ?? "") < usage.start { usage.start = point["start"] as? String ?? usage.start }
            if (point["end"] as? String ?? "") > usage.end { usage.end = point["end"] as? String ?? usage.end }
            if let count = values["inviteCount"] as? Int { usage.invites = (usage.invites ?? 0) + count }
            if let count = values["installCount"] as? Int { usage.installs = (usage.installs ?? 0) + count }
            usage.sessions += values["sessionCount"] as? Int ?? 0
            usage.crashes += values["crashCount"] as? Int ?? 0
            usage.feedback += values["feedbackCount"] as? Int ?? 0
        }
        return usage
    }

    static func buildUsage(_ page: [String: Any]) -> Usage {
        (page["data"] as? [[String: Any]] ?? []).map(usage(from:)).reduce(into: Usage()) { total, next in
            total = combine(total, next)
        }
    }

    /// Keyed by tester ID, from betaTesterUsages grouped by betaTesters.
    static func testerUsages(_ page: [String: Any]) -> [String: Usage] {
        var result: [String: Usage] = [:]
        for entry in page["data"] as? [[String: Any]] ?? [] {
            guard let id = (((entry["dimensions"] as? [String: Any])?["betaTesters"] as? [String: Any])?["data"] as? [String: Any])?["id"] as? String
            else { continue }
            result[id] = combine(result[id] ?? Usage(), usage(from: entry))
        }
        return result
    }

    static func testers(_ page: [String: Any]) -> [Tester] {
        (page["data"] as? [[String: Any]] ?? []).compactMap { item in
            guard let id = item["id"] as? String, let fields = item["attributes"] as? [String: Any] else { return nil }
            let fullName = [fields["firstName"], fields["lastName"]].compactMap { $0 as? String }.joined(separator: " ")
            // Public-link testers are all "Anonymous"; the ID prefix tells them apart from run to run.
            let name = fields["email"] as? String ?? (fullName.isEmpty ? "Tester" : fullName) + " " + id.prefix(8)
            let devices = (fields["appDevices"] as? [[String: Any]] ?? []).map { device in
                [device["appBuildVersion"] as? String ?? "?",
                 (device["model"] as? String ?? "?").replacingOccurrences(of: "_", with: ","),
                 "iOS " + (device["osVersion"] as? String ?? "?")].joined(separator: "  ")
            }
            return Tester(id: id, name: name, state: fields["state"] as? String ?? "?",
                          inviteType: fields["inviteType"] as? String ?? "?", devices: devices)
        }
    }

    static func combine(_ a: Usage, _ b: Usage) -> Usage {
        func add(_ x: Int?, _ y: Int?) -> Int? { x == nil && y == nil ? nil : (x ?? 0) + (y ?? 0) }
        return Usage(start: a.start.isEmpty ? b.start : min(a.start, b.start.isEmpty ? a.start : b.start),
                     end: max(a.end, b.end), invites: add(a.invites, b.invites), installs: add(a.installs, b.installs),
                     sessions: a.sessions + b.sessions, crashes: a.crashes + b.crashes, feedback: a.feedback + b.feedback)
    }
}

struct API {
    static let base = URL(string: "https://api.appstoreconnect.apple.com/v1/")!
    let config: Config
    let pem: String

    init(config: Config) throws {
        self.config = config
        pem = try String(contentsOf: config.keyURL, encoding: .utf8)
    }

    /// A fresh token per call, so a long wait for processing never outlives one.
    @discardableResult
    func request(_ method: String, _ path: String, query: [String: String] = [:],
                 body: [String: Any]? = nil) async throws -> [String: Any] {
        guard var components = URLComponents(url: Self.base.appending(path: path), resolvingAgainstBaseURL: false) else {
            throw CLIError.failed("Could not form a URL for \(path).")
        }
        if !query.isEmpty {
            components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = components.url else { throw CLIError.failed("Could not form a URL for \(path).") }
        var request = URLRequest(url: url)
        request.httpMethod = method
        let token = try Token.make(keyID: config.keyID, issuerID: config.issuerID, pem: pem)
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let object = data.isEmpty ? nil : try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard (200..<300).contains(status) else {
            let details = (object?["errors"] as? [[String: Any]])?
                .compactMap { $0["detail"] as? String ?? $0["title"] as? String }
                .joined(separator: " ")
            throw CLIError.api(status: status, detail: details ?? String(decoding: data, as: UTF8.self))
        }
        if !data.isEmpty, object == nil {
            throw CLIError.failed("App Store Connect sent a response for \(path) that isn't JSON.")
        }
        return object ?? [:]
    }

    func builds(number: String? = nil, limit: Int = 10) async throws -> [BuildInfo] {
        var query = ["filter[app]": Config.appID, "sort": "-uploadedDate", "limit": String(limit),
                     "include": "preReleaseVersion,buildBetaDetail"]
        if let number { query["filter[version]"] = number }
        let page = try await request("GET", "builds", query: query)
        let included = page["included"] as? [[String: Any]] ?? []
        func attributes(of type: String, id: String?) -> [String: Any] {
            included.first { $0["type"] as? String == type && $0["id"] as? String == id }?["attributes"] as? [String: Any] ?? [:]
        }
        return (page["data"] as? [[String: Any]] ?? []).compactMap { item in
            guard let id = item["id"] as? String, let fields = item["attributes"] as? [String: Any] else { return nil }
            let relationships = item["relationships"] as? [String: Any] ?? [:]
            func related(_ name: String) -> String? {
                ((relationships[name] as? [String: Any])?["data"] as? [String: Any])?["id"] as? String
            }
            let detail = attributes(of: "buildBetaDetails", id: related("buildBetaDetail"))
            return BuildInfo(
                id: id,
                number: fields["version"] as? String ?? "?",
                version: attributes(of: "preReleaseVersions", id: related("preReleaseVersion"))["version"] as? String ?? "?",
                processing: fields["processingState"] as? String ?? "?",
                uploaded: fields["uploadedDate"] as? String ?? "",
                internalState: detail["internalBuildState"] as? String ?? "-",
                externalState: detail["externalBuildState"] as? String ?? "-")
        }
    }

    /// The newest upload with that build number; the number alone can repeat across versions.
    func build(number: String) async throws -> BuildInfo {
        guard let build = try await builds(number: number, limit: 5).first else {
            throw CLIError.notFound("App Store Connect has no build \(number) for Funston yet.")
        }
        return build
    }

    func groups() async throws -> [BetaGroup] {
        let page = try await request("GET", "apps/\(Config.appID)/betaGroups", query: ["limit": "200"])
        return (page["data"] as? [[String: Any]] ?? []).compactMap { item in
            guard let id = item["id"] as? String, let fields = item["attributes"] as? [String: Any],
                  let name = fields["name"] as? String else { return nil }
            return BetaGroup(id: id, name: name, isInternal: fields["isInternalGroup"] as? Bool ?? false,
                             publicLink: fields["publicLinkEnabled"] as? Bool ?? false)
        }
    }

    func buildUsage(_ build: BuildInfo) async throws -> Usage {
        UsageParsing.buildUsage(try await request("GET", "builds/\(build.id)/metrics/betaBuildUsages"))
    }

    func testerUsages(days: Int) async throws -> [String: Usage] {
        UsageParsing.testerUsages(try await request("GET", "apps/\(Config.appID)/metrics/betaTesterUsages",
                                                    query: ["groupBy": "betaTesters", "period": "P\(days)D", "limit": "200"]))
    }

    func testers() async throws -> [Tester] {
        UsageParsing.testers(try await request("GET", "betaTesters", query: ["filter[apps]": Config.appID, "limit": "200"]))
    }

    func buildIDs(in group: BetaGroup) async throws -> Set<String> {
        let page = try await request("GET", "betaGroups/\(group.id)/relationships/builds", query: ["limit": "200"])
        return Set((page["data"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String })
    }

    func add(_ build: BuildInfo, to group: BetaGroup) async throws {
        try await request("POST", "betaGroups/\(group.id)/relationships/builds",
                          body: ["data": [["type": "builds", "id": build.id]]])
    }

    func submitForReview(_ build: BuildInfo) async throws {
        let submission: [String: Any] = [
            "type": "betaAppReviewSubmissions",
            "relationships": ["build": ["data": ["type": "builds", "id": build.id]]],
        ]
        try await request("POST", "betaAppReviewSubmissions", body: ["data": submission])
    }

    /// The "What to Test" text testers see, in English.
    func setNotes(_ notes: String, for build: BuildInfo) async throws {
        let existing = try await request("GET", "builds/\(build.id)/betaBuildLocalizations")
        let english = (existing["data"] as? [[String: Any]] ?? []).first {
            ($0["attributes"] as? [String: Any])?["locale"] as? String == "en-US"
        }
        if let id = english?["id"] as? String {
            let update: [String: Any] = ["type": "betaBuildLocalizations", "id": id, "attributes": ["whatsNew": notes]]
            try await request("PATCH", "betaBuildLocalizations/\(id)", body: ["data": update])
        } else {
            let localization: [String: Any] = [
                "type": "betaBuildLocalizations",
                "attributes": ["locale": "en-US", "whatsNew": notes],
                "relationships": ["build": ["data": ["type": "builds", "id": build.id]]],
            ]
            try await request("POST", "betaBuildLocalizations", body: ["data": localization])
        }
    }
}

// MARK: - Commands

enum Commands {
    /// External states after which a build needs no new review submission.
    static let alreadySubmitted: Set<String> = ["WAITING_FOR_BETA_REVIEW", "IN_BETA_REVIEW", "BETA_APPROVED", "IN_BETA_TESTING"]
    static let pollInterval: Duration = .seconds(30)
    static let defaultWaitMinutes = 60

    static func builds(_ options: Options) async throws {
        let api = try API(config: Config.load())
        let builds = try await api.builds(limit: try options.number("--limit", default: 10))
        let groups = try await api.groups()
        var membership: [String: [String]] = [:]
        for group in groups {
            for id in try await api.buildIDs(in: group) { membership[id, default: []].append(group.name) }
        }
        for build in builds {
            let groupNames = membership[build.id]?.sorted().joined(separator: ", ") ?? "no groups"
            print("\(build.version) (\(build.number))  \(build.processing)  internal \(build.internalState)  external \(build.externalState)  \(groupNames)")
        }
        if builds.isEmpty { print("No builds yet.") }
    }

    static func groups() async throws {
        let api = try API(config: Config.load())
        for group in try await api.groups() {
            let kind = group.isInternal ? "internal" : "external"
            print("\(group.name): \(kind)\(group.publicLink ? ", public link on" : "")")
        }
    }

    /// The usage windows Apple's betaTesterUsages accepts.
    static let usagePeriods = [7, 30, 90, 365]

    static func stats(_ options: Options) async throws {
        let days = try options.number("--days", default: 365)
        guard usagePeriods.contains(days) else {
            throw CLIError.usage("--days must be one of \(usagePeriods.map(String.init).joined(separator: ", ")); Apple offers only those.")
        }
        let api = try API(config: Config.load())
        let builds = try await api.builds(limit: try options.number("--limit", default: 10))
        var buildRows: [(BuildInfo, Usage)] = []
        for build in builds { buildRows.append((build, try await api.buildUsage(build))) }
        let usages = try await api.testerUsages(days: days)
        let testers = try await api.testers()
        print(statsReport(builds: buildRows, testers: testers, usages: usages, days: days))
    }

    static func statsReport(builds: [(BuildInfo, Usage)], testers: [Tester], usages: [String: Usage], days: Int) -> String {
        func count(_ value: Int?) -> String { value.map(String.init) ?? "-" }
        /// Counts line up on the right; every other column reads left to right.
        func table(_ rows: [[String]], counts: Set<Int>) -> [String] {
            let widths = rows.reduce(into: [Int]()) { widths, row in
                for (index, cell) in row.enumerated() {
                    if index < widths.count { widths[index] = max(widths[index], cell.count) } else { widths.append(cell.count) }
                }
            }
            return rows.map { row in
                row.enumerated().map { index, cell in
                    counts.contains(index) ? String(repeating: " ", count: widths[index] - cell.count) + cell
                        : cell.padding(toLength: widths[index], withPad: " ", startingAt: 0)
                }.joined(separator: "  ").trimmingCharacters(in: .whitespaces)
            }
        }
        var lines: [String] = []
        let window = builds.map(\.1).first { !$0.start.isEmpty }
        lines.append("Builds" + (window.map { ", usage \($0.start) to \($0.end)" } ?? ""))
        if builds.isEmpty { lines.append("No builds yet.") } else {
            lines += table([["build", "invites", "installs", "sessions", "crashes", "feedback"]] + builds.map { build, usage in
                ["\(build.version) (\(build.number))", count(usage.invites), count(usage.installs),
                 String(usage.sessions), String(usage.crashes), String(usage.feedback)]
            }, counts: [1, 2, 3, 4, 5])
        }
        let testerWindow = usages.values.first { !$0.start.isEmpty }
        lines.append("")
        lines.append("Testers, usage over the last \(days) days" + (testerWindow.map { " (\($0.start) to \($0.end))" } ?? ""))
        if testers.isEmpty { lines.append("No testers yet.") } else {
            let sorted = testers.sorted { (usages[$0.id]?.sessions ?? 0, $1.name) > (usages[$1.id]?.sessions ?? 0, $0.name) }
            lines += table([["tester", "state", "joined by", "sessions", "crashes", "feedback", "installed on"]] + sorted.map { tester in
                let usage = usages[tester.id] ?? Usage()
                return [tester.name, tester.state, tester.inviteType, String(usage.sessions), String(usage.crashes),
                        String(usage.feedback), tester.devices.isEmpty ? "-" : tester.devices.joined(separator: "; ")]
            }, counts: [3, 4, 5])
            let unlisted = Set(usages.keys).subtracting(testers.map(\.id))
            if !unlisted.isEmpty { lines.append("\(unlisted.count) tester(s) have usage but aren't in the tester list.") }
        }
        return lines.joined(separator: "\n")
    }

    static func distribute(_ options: Options) async throws {
        guard let number = options.positional.first else { throw CLIError.usage("Name the build: distribute <build>") }
        let config = try Config.load()
        try await distribute(number: number, groups: options.values["--group"] ?? config.groups,
                             notes: options.value("--notes"), submit: !options.flags.contains("--no-submit"),
                             api: API(config: config))
    }

    static func distribute(number: String, groups names: [String], notes: String?, submit: Bool, api: API) async throws {
        let build = try await api.build(number: number)
        guard build.processing == "VALID" else {
            throw CLIError.failed("Build \(number) is \(build.processing), not processed yet. Run: Scripts/testflight wait \(number)")
        }
        let available = try await api.groups()
        let targets = try names.map { name in
            guard let group = available.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
                throw CLIError.notFound("No beta group named \"\(name)\". Groups: \(available.map(\.name).joined(separator: ", ")).")
            }
            return group
        }
        if let notes {
            try await api.setNotes(notes, for: build)
            print("Set What to Test for build \(number).")
        }
        for group in targets {
            if try await api.buildIDs(in: group).contains(build.id) {
                print("Build \(number) is already in \(group.name).")
            } else {
                try await api.add(build, to: group)
                print("Added build \(number) to \(group.name).")
            }
        }
        guard submit, targets.contains(where: { !$0.isInternal }) else { return }
        if alreadySubmitted.contains(build.externalState) {
            print("Build \(number) is already \(build.externalState); no new review submission.")
        } else {
            try await api.submitForReview(build)
            print("Submitted build \(number) for Beta App Review.")
        }
    }

    static func wait(_ options: Options) async throws {
        guard let number = options.positional.first else { throw CLIError.usage("Name the build: wait <build>") }
        let api = try API(config: Config.load())
        try await waitForProcessing(number: number, minutes: try options.number("--minutes", default: defaultWaitMinutes), api: api)
    }

    /// A fresh upload takes a minute or two to appear at all, so "not found" means keep waiting.
    static func waitForProcessing(number: String, minutes: Int, api: API) async throws {
        let deadline = ContinuousClock.now + .seconds(minutes * 60)
        var lastState = ""
        while ContinuousClock.now < deadline {
            let state = try await api.builds(number: number, limit: 5).first?.processing ?? "NOT_LISTED_YET"
            if state != lastState { print("Build \(number): \(state)"); lastState = state }
            switch state {
            case "VALID": return
            case "FAILED", "INVALID": throw CLIError.failed("App Store Connect marked build \(number) \(state).")
            default: try await Task.sleep(for: pollInterval)
            }
        }
        throw CLIError.timedOut("Build \(number) was still \(lastState) after \(minutes) minutes.")
    }

    static func ship(_ options: Options) async throws {
        let repository = try Repository()
        let dryRun = options.flags.contains("--dry-run")
        let config = try? Config.load()
        let api = try config.map { try API(config: $0) }
        let current = try repository.buildNumber()
        let uploaded = try await api?.builds(limit: 50).compactMap { Int($0.number) }.max()
        // Without the API the highest uploaded number is unknown; skipping a number is
        // harmless, reusing one makes the upload fail.
        let next = uploaded.map { max(current, $0 + 1) } ?? current + 1
        let keepCarPlay = options.flags.contains("--carplay")
        let groups = options.values["--group"] ?? config?.groups ?? Config.defaultGroups
        let version = try repository.marketingVersion()
        print("Funston \(version) build \(next)"
              + (uploaded.map { "; highest on App Store Connect is \($0)" } ?? "; App Store Connect not checked (no API key)"))
        if !keepCarPlay { print("CarPlay entitlement left out: the developer account doesn't have it. Pass --carplay once Apple grants it.") }
        if dryRun {
            print("Dry run: would set the build number, archive, upload, wait, then distribute to \(groups.joined(separator: ", ")).")
            return
        }
        if next != current {
            try repository.setBuildNumber(next)
            print("Set the build number to \(next) in the Xcode project and project.yml.")
        }
        let run = repository.root.appending(path: "output/testflight/\(next)")
        try FileManager.default.createDirectory(at: run, withIntermediateDirectories: true)
        let archive = run.appending(path: "Funston.xcarchive")
        print("Archiving…")
        try Shell.run(["xcodebuild", "archive", "-project", "Funston.xcodeproj", "-scheme", "Funston",
                       "-configuration", "Release", "-destination", "generic/platform=iOS",
                       "-archivePath", archive.path, "-allowProvisioningUpdates"]
                      + (keepCarPlay ? [] : ["CODE_SIGN_ENTITLEMENTS="]),
                      in: repository.root, log: run.appending(path: "archive.log"))
        print("Uploading…")
        let exportOptions = run.appending(path: "ExportOptions.plist")
        let exportSettings: [String: Any] = [
            "method": "app-store-connect", "destination": "upload", "teamID": Config.teamID,
            "signingStyle": "automatic", "uploadSymbols": true, "manageAppVersionAndBuildNumber": false,
        ]
        try PropertyListSerialization.data(fromPropertyList: exportSettings, format: .xml, options: 0).write(to: exportOptions)
        try Shell.run(["xcodebuild", "-exportArchive", "-archivePath", archive.path,
                       "-exportOptionsPlist", exportOptions.path, "-exportPath", run.appending(path: "export").path,
                       "-allowProvisioningUpdates"],
                      in: repository.root, log: run.appending(path: "upload.log"), environment: Shell.withoutHomebrew())
        print("Uploaded build \(next). Logs are in \(run.path).")
        guard let api else {
            print("No API key yet, so stopping here. " + Config.setupHelp)
            return
        }
        try await waitForProcessing(number: String(next), minutes: defaultWaitMinutes, api: api)
        try await distribute(number: String(next), groups: groups, notes: options.value("--notes"),
                             submit: !options.flags.contains("--no-submit"), api: api)
    }

    /// Responses recorded from App Store Connect on 2026-10-19, trimmed to two
    /// entries each, with the tester IDs replaced. The shapes are Apple's.
    static let recordedBuildUsage = #"""
    {"data":[{"dataPoints":[{"end":"2026-10-20","start":"2025-10-20","values":{"crashCount":0,"feedbackCount":0,"installCount":6,"inviteCount":7,"sessionCount":153}}],"type":"betaBuildUsages"}],"meta":{"paging":{"limit":50,"total":1}}}
    """#
    static let recordedTesterUsage = #"""
    {"data":[{"dataPoints":[{"end":"2026-10-20","start":"2025-10-20","values":{"crashCount":0,"feedbackCount":0,"sessionCount":165}}],"dimensions":{"betaTesters":{"data":{"id":"11111111-aaaa-4aaa-8aaa-aaaaaaaaaaaa","type":"betaTesters"}}},"type":"appsBetaTesterUsages"},{"dataPoints":[{"end":"2026-10-20","start":"2025-10-20","values":{"crashCount":0,"feedbackCount":0,"sessionCount":2}}],"dimensions":{"betaTesters":{"data":{"id":"22222222-bbbb-4bbb-8bbb-bbbbbbbbbbbb","type":"betaTesters"}}},"type":"appsBetaTesterUsages"}],"meta":{"paging":{"limit":50,"total":8}}}
    """#
    static let recordedTesters = #"""
    {"data":[{"attributes":{"appDevices":[{"appBuildVersion":"0.2.0 (16)","model":"iPhone15_3","osVersion":"27.2","platform":"IOS"}],"email":null,"firstName":"Anonymous","inviteType":"PUBLIC_LINK","lastName":null,"state":"INSTALLED"},"id":"11111111-aaaa-4aaa-8aaa-aaaaaaaaaaaa","type":"betaTesters"},{"attributes":{"appDevices":[],"email":null,"firstName":"Anonymous","inviteType":"PUBLIC_LINK","lastName":null,"state":"REVOKED"},"id":"22222222-bbbb-4bbb-8bbb-bbbbbbbbbbbb","type":"betaTesters"}],"meta":{"paging":{"limit":200,"total":8}}}
    """#

    static func statsSelftest(_ check: (Bool, String) throws -> Void) throws {
        func page(_ text: String) -> [String: Any] {
            (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
        }
        let build = UsageParsing.buildUsage(page(recordedBuildUsage))
        try check(build == Usage(start: "2025-10-20", end: "2026-10-20", invites: 7, installs: 6, sessions: 153, crashes: 0, feedback: 0),
                  "build usage reads invites, installs, sessions, crashes and feedback")
        let usages = UsageParsing.testerUsages(page(recordedTesterUsage))
        try check(usages["11111111-aaaa-4aaa-8aaa-aaaaaaaaaaaa"]?.sessions == 165 && usages["22222222-bbbb-4bbb-8bbb-bbbbbbbbbbbb"]?.sessions == 2
                  && usages.values.allSatisfy { $0.invites == nil && $0.installs == nil },
                  "tester usage is keyed by tester and carries no invite or install counts")
        let testers = UsageParsing.testers(page(recordedTesters))
        try check(testers.map(\.name) == ["Anonymous 11111111", "Anonymous 22222222"], "anonymous testers are told apart by ID prefix")
        try check(testers.first?.devices == ["0.2.0 (16)  iPhone15,3  iOS 27.2"] && testers.last?.devices == [],
                  "devices read build, model identifier and iOS version")
        try check(UsageParsing.buildUsage(page(#"{"data":[]}"#)) == Usage(), "a build with no usage reads as zero")
        let info = BuildInfo(id: "b", number: "16", version: "0.2.0", processing: "VALID", uploaded: "", internalState: "", externalState: "")
        let report = statsReport(builds: [(info, build)], testers: testers, usages: usages, days: 365).split(separator: "\n").map(String.init)
        try check(report.contains("0.2.0 (16)        7         6       153        0         0"), "the build row lines counts up on the right")
        let installed = report.first { $0.hasPrefix("Anonymous 11111111") }
        let revoked = report.first { $0.hasPrefix("Anonymous 22222222  REVOKED") }
        var deviceColumn: Int?, dashColumn: Int?
        if let installed, let start = installed.range(of: "0.2.0 (16)")?.lowerBound {
            deviceColumn = installed.distance(from: installed.startIndex, to: start)
        }
        if let revoked, let dash = revoked.lastIndex(of: "-") { dashColumn = revoked.distance(from: revoked.startIndex, to: dash) }
        try check(deviceColumn != nil && deviceColumn == dashColumn,
                  "a tester without a device still gets a row, its dash starting where device text starts")
    }

    static func setup() throws {
        let config = try Config.load()
        _ = try Token.make(keyID: config.keyID, issuerID: config.issuerID, pem: String(contentsOf: config.keyURL, encoding: .utf8))
        print("Key \(config.keyID) loads and signs. Default groups: \(config.groups.joined(separator: ", ")).")
        print("Run Scripts/testflight groups to check it against App Store Connect.")
    }

    /// Signs a token with a throwaway key in Apple's .p8 format and checks it the way a server would.
    static func selftest() throws {
        let key = P256.Signing.PrivateKey()
        let issued = Date(timeIntervalSince1970: 1_800_000_000)
        let token = try Token.make(keyID: "TESTKEY123", issuerID: "test-issuer", pem: key.pemRepresentation, now: issued)
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        func check(_ condition: Bool, _ what: String) throws {
            guard condition else { throw CLIError.failed("selftest failed: \(what)") }
            print("ok  \(what)")
        }
        try check(key.pemRepresentation.hasPrefix("-----BEGIN PRIVATE KEY-----"), "throwaway key uses the PKCS#8 form Apple's .p8 files use")
        try check(parts.count == 3, "token has three parts")
        let header = parts.count == 3 ? Token.decode(parts[0]).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } : nil
        let claims = parts.count == 3 ? Token.decode(parts[1]).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } : nil
        try check(header?["alg"] as? String == "ES256" && header?["kid"] as? String == "TESTKEY123" && header?["typ"] as? String == "JWT",
                  "header names ES256 and the key ID")
        try check(claims?["iss"] as? String == "test-issuer" && claims?["aud"] as? String == Token.audience, "claims name the issuer and audience")
        let lifetime = (claims?["exp"] as? Int ?? 0) - (claims?["iat"] as? Int ?? 0)
        try check(lifetime > 0 && lifetime <= 20 * 60, "token lives \(lifetime) seconds, within Apple's 20 minutes")
        let signature = parts.count == 3 ? Token.decode(parts[2]) : nil
        try check(signature?.count == 64, "signature is the 64-byte r||s form")
        let valid = signature.flatMap { try? P256.Signing.ECDSASignature(rawRepresentation: $0) }
            .map { key.publicKey.isValidSignature($0, for: Data((parts[0] + "." + parts[1]).utf8)) } ?? false
        try check(valid, "signature verifies against the public key")
        try statsSelftest(check)
        print("selftest passed")
    }
}

// MARK: - Repository and shell

struct Repository {
    let root: URL
    var project: URL { root.appending(path: "Funston.xcodeproj/project.pbxproj") }
    var spec: URL { root.appending(path: "project.yml") }

    init() throws {
        guard let path = ProcessInfo.processInfo.environment["FUNSTON_ROOT"] else {
            throw CLIError.usage("Run this through Scripts/testflight so it can find the repository.")
        }
        root = URL(filePath: path)
    }

    func buildNumber() throws -> Int {
        guard let text = try firstMatch(#"CURRENT_PROJECT_VERSION = (\d+);"#, in: project), let number = Int(text) else {
            throw CLIError.failed("Couldn't read CURRENT_PROJECT_VERSION from the Xcode project.")
        }
        return number
    }

    func marketingVersion() throws -> String {
        guard let version = try firstMatch(#"MARKETING_VERSION = ([0-9.]+);"#, in: project) else {
            throw CLIError.failed("Couldn't read MARKETING_VERSION from the Xcode project.")
        }
        return version
    }

    /// Keeps the XcodeGen spec in step so regenerating the project can't roll the number back.
    func setBuildNumber(_ number: Int) throws {
        try replace(#"CURRENT_PROJECT_VERSION = \d+;"#, with: "CURRENT_PROJECT_VERSION = \(number);", in: project)
        try replace(#"CURRENT_PROJECT_VERSION: "\d+""#, with: "CURRENT_PROJECT_VERSION: \"\(number)\"", in: spec)
    }

    private func firstMatch(_ pattern: String, in file: URL) throws -> String? {
        let text = try String(contentsOf: file, encoding: .utf8)
        let expression = try NSRegularExpression(pattern: pattern)
        guard let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    private func replace(_ pattern: String, with replacement: String, in file: URL) throws {
        let text = try String(contentsOf: file, encoding: .utf8)
        let expression = try NSRegularExpression(pattern: pattern)
        let range = NSRange(text.startIndex..., in: text)
        guard expression.numberOfMatches(in: text, range: range) > 0 else {
            throw CLIError.failed("Found no build number to change in \(file.lastPathComponent).")
        }
        let updated = expression.stringByReplacingMatches(in: text, range: range,
                                                          withTemplate: NSRegularExpression.escapedTemplate(for: replacement))
        try updated.write(to: file, atomically: true, encoding: .utf8)
    }
}

enum Shell {
    /// Xcode's export runs /usr/bin/rsync, which starts its helper by name from PATH.
    /// Homebrew's rsync 3.x answers instead and rejects a flag, so export fails with "Copy failed".
    static func withoutHomebrew() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let path = (environment["PATH"] ?? "").split(separator: ":")
            .filter { !$0.hasPrefix("/opt/homebrew") && !$0.hasPrefix("/usr/local") }
        environment["PATH"] = (path.isEmpty ? ["/usr/bin", "/bin", "/usr/sbin", "/sbin"] : path).joined(separator: ":")
        return environment
    }

    static func run(_ arguments: [String], in directory: URL, log: URL, environment: [String: String]? = nil) throws {
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close() }
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/env")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        if let environment { process.environment = environment }
        process.standardOutput = handle
        process.standardError = handle
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let tail = (try? String(contentsOf: log, encoding: .utf8))?
                .split(separator: "\n").filter { $0.contains("error") }.suffix(5).joined(separator: "\n") ?? ""
            throw CLIError.failed("\(arguments.prefix(2).joined(separator: " ")) failed (exit \(process.terminationStatus)). See \(log.path)\n\(tail)")
        }
    }
}
