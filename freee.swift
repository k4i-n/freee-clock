// freee clock: clocks in and out on freee HR (人事労務) from a menu bar app. Swift + AppKit, no dependencies.
//
//   freee bar             the menu bar app (launchd job local.freee-clock.bar). On working weekdays it clocks in and out
//                         at a random time inside the windows set in Settings (default 08:15-09:00 and 18:00-19:00)
//                         while the Mac is in use; in the last 30s the icon flashes and the menu offers
//                         Clock now / Delay 10 min / Skip. The first start opens Setup to sign in to freee.
//   freee setup           open Setup in the running menu bar app
//   freee status          read-only: who, today's day type, what can be punched now
//   freee in | out        punch now
//   freee demo [in|out]   40s countdown in the running menu bar app, no punch
//   freee selftest        offline checks with a fake clock, freee and Keychain (install.sh runs them before loading)
//
// Secrets (your freee app's client secret, the tokens) live in the login Keychain, service "freee-clock".
// Files: ~/.config/freee-clock/config.json (company, employee) and settings.json; log ~/Library/Logs/freee-clock.log.
// Build: install.sh (swiftc -O freee.swift -o freee)
import AppKit
import IOKit
import Network
import Security

// MARK: - Settings

typealias HM = (h: Int, m: Int)

struct Settings {
    var inStart: HM = (h: 8, m: 15), inEnd: HM = (h: 9, m: 0)
    var outStart: HM = (h: 18, m: 0), outEnd: HM = (h: 19, m: 0)
    var lateIn = true, lateOut = false
}

var settings = Settings()

enum Kind: String, CaseIterable {
    case clockIn = "in", clockOut = "out"
    var type: String { self == .clockIn ? "clock_in" : "clock_out" }
    // [start, end): when the automatic punch may happen
    var window: (start: HM, end: HM) {
        self == .clockIn ? (start: settings.inStart, end: settings.inEnd) : (start: settings.outStart, end: settings.outEnd)
    }
    // the window was missed: clock when the Mac is next used instead
    var late: Bool { self == .clockIn ? settings.lateIn : settings.lateOut }
}

let idleMax = 600.0  // seconds without keyboard/mouse input before the Mac counts as unattended
let delayStep = 600.0  // Delay 10 min
let showWithin = 30.0  // the menu shows the countdown and the icon flashes in the last 30s
let apiBase = "https://api.freee.co.jp/hr/api/v1"
let oauth = "https://accounts.secure.freee.co.jp/public_api"
let callbackPort: UInt16 = 8370
let callbackURL = "http://127.0.0.1:\(callbackPort)/callback"
let oobRedirect = "urn:ietf:wg:oauth:2.0:oob"  // what tokens of older versions were issued for
let appsPage = "https://app.secure.freee.co.jp/developers/applications"
let usage = "usage: freee bar | setup | status | in | out | demo [in|out] | selftest"
var configDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/freee-clock")  // selftest swaps these
var envURL = Bundle.main.executableURL!.resolvingSymlinksInPath().deletingLastPathComponent().appendingPathComponent(".env")
var oldTokenURL: URL { configDir.appendingPathComponent("token.json") }
var confURL: URL { configDir.appendingPathComponent("config.json") }
var settingsURL: URL { configDir.appendingPathComponent("settings.json") }

func parseHM(_ v: Any?) -> HM? {
    guard let s = v as? String else { return nil }
    let p = s.split(separator: ":").compactMap { Int($0) }
    guard p.count == 2, (0..<24).contains(p[0]), (0..<60).contains(p[1]) else { return nil }
    return (h: p[0], m: p[1])
}

func mins(_ t: HM) -> Int { t.h * 60 + t.m }

extension Settings {
    init(json: [String: Any]) {
        self.init()
        inStart = parseHM(json["clock_in_start"]) ?? inStart
        inEnd = parseHM(json["clock_in_end"]) ?? inEnd
        outStart = parseHM(json["clock_out_start"]) ?? outStart
        outEnd = parseHM(json["clock_out_end"]) ?? outEnd
        lateIn = json["late_clock_in"] as? Bool ?? lateIn
        lateOut = json["late_clock_out"] as? Bool ?? lateOut
    }

    var json: [String: Any] {
        ["clock_in_start": hm(inStart), "clock_in_end": hm(inEnd), "clock_out_start": hm(outStart),
         "clock_out_end": hm(outEnd), "late_clock_in": lateIn, "late_clock_out": lateOut]
    }

    // why these settings cannot be used, or nil
    var problem: String? {
        if mins(inStart) >= mins(inEnd) { return "Clock in: start must be before end" }
        if mins(outStart) >= mins(outEnd) { return "Clock out: start must be before end" }
        if mins(inEnd) > mins(outStart) { return "Clock in must end before clock out starts" }
        return nil
    }

    var summary: String {
        "clock in \(hm(inStart))-\(hm(inEnd)) (late \(lateIn ? "on" : "off")), "
            + "clock out \(hm(outStart))-\(hm(outEnd)) (late \(lateOut ? "on" : "off"))"
    }
}

func loadSettings() -> Settings {
    guard let data = try? Data(contentsOf: settingsURL),
          let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return Settings() }
    let s = Settings(json: j)
    return s.problem == nil ? s : Settings()
}

func saveSettings(_ s: Settings) throws {
    try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: s.json, options: [.prettyPrinted, .sortedKeys]).write(to: settingsURL, options: .atomic)
}

// MARK: - Helpers

struct Fail: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

let cal = Calendar.current
let notSignedIn = Fail("not signed in: menu bar clock > Settings > Set up")

func fmt(_ d: Date, _ pattern: String) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = pattern
    return f.string(from: d)
}

func ymd(_ d: Date) -> String { fmt(d, "yyyy-MM-dd") }
func at(_ day: Date, _ t: HM) -> Date { cal.date(bySettingHour: t.h, minute: t.m, second: 0, of: day)! }
func hm(_ t: HM) -> String { String(format: "%02d:%02d", t.h, t.m) }

func logLine(_ msg: String) { print("\(fmt(Date(), "yyyy-MM-dd HH:mm:ss")) \(msg)") }

func osaNotify(_ msg: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    p.arguments = ["-e", "on run argv", "-e", "display notification (item 1 of argv) with title \"freee clock\"", "-e", "end run", msg]
    try? p.run()
}

func hidIdleSeconds() -> Double {
    let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"))
    guard service != 0 else { return 0 }
    defer { IOObjectRelease(service) }
    let v = IORegistryEntryCreateCFProperty(service, "HIDIdleTime" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    return ((v as? NSNumber)?.doubleValue ?? 0) / 1e9
}

func openShift(_ kind: Kind, _ base: String) -> String {
    "Not clocked \(kind.rawValue): the \(base) shift is still open. Fix it in freee, then `freee \(kind.rawValue)`"
}

// MARK: - Keychain

protocol SecretStore {
    func get(_ account: String) -> [String: Any]?
    func set(_ account: String, _ value: [String: Any]) throws
    func delete(_ account: String)
}

// one generic password per account ("app": client id and secret, "token": the OAuth tokens), JSON in the password
struct Keychain: SecretStore {
    func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "freee-clock", kSecAttrAccount as String: account]
    }

    func get(_ account: String) -> [String: Any]? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    func set(_ account: String, _ value: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: value)
        var status = SecItemUpdate(query(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var q = query(account)
            q[kSecValueData as String] = data
            q[kSecAttrLabel as String] = "freee clock (\(account))"
            status = SecItemAdd(q as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw Fail("Keychain: cannot save \(account): \(SecCopyErrorMessageString(status, nil) as String? ?? "\(status)")")
        }
    }

    func delete(_ account: String) { SecItemDelete(query(account) as CFDictionary) }
}

final class MemoryStore: SecretStore {
    var items: [String: [String: Any]] = [:]
    func get(_ account: String) -> [String: Any]? { items[account] }
    func set(_ account: String, _ value: [String: Any]) throws { items[account] = value }
    func delete(_ account: String) { items[account] = nil }
}

var secrets: SecretStore = Keychain()  // selftest swaps in a MemoryStore

func parseEnv(_ text: String) -> [String: String] {
    var env: [String: String] = [:]
    for raw in text.split(separator: "\n") {
        var line = raw.trimmingCharacters(in: .whitespaces)
        if line.hasPrefix("export ") { line.removeFirst(7) }
        guard !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") else { continue }
        env[line[..<eq].trimmingCharacters(in: .whitespaces)] =
            line[line.index(after: eq)...].trimmingCharacters(in: CharacterSet(charactersIn: " \t'\""))
    }
    return env
}

// older versions kept the app credentials in .env next to the binary and the tokens in token.json: move them in once
func importOldSecrets() {
    if secrets.get("app") == nil, let text = try? String(contentsOf: envURL, encoding: .utf8) {
        let env = parseEnv(text)
        if let id = env["ClientID"], let secret = env["ClientSecret"], !id.isEmpty, !secret.isEmpty,
           (try? secrets.set("app", ["client_id": id, "client_secret": secret])) != nil {
            logLine("imported the app credentials from \(envURL.path) into the Keychain; that file can be deleted")
        }
    }
    if secrets.get("token") == nil, let data = try? Data(contentsOf: oldTokenURL),
       var t = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
        t["redirect_uri"] = oobRedirect
        if (try? secrets.set("token", t)) != nil {
            try? FileManager.default.removeItem(at: oldTokenURL)
            logLine("moved \(oldTokenURL.path) into the Keychain")
        }
    }
}

// MARK: - freee API

func formEncode(_ form: [String: String]) -> String {
    let plain = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    return form.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: plain)!)" }.joined(separator: "&")
}

// blocking request; call it off the main thread in the app
func http(_ method: String, _ url: String, token: String? = nil, json: Any? = nil, form: [String: String]? = nil) throws -> Any {
    var req = URLRequest(url: URL(string: url)!, timeoutInterval: 30)
    req.httpMethod = method
    req.setValue("application/json", forHTTPHeaderField: "Accept")
    if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
    if let json {
        req.httpBody = try JSONSerialization.data(withJSONObject: json)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }
    if let form {
        req.httpBody = Data(formEncode(form).utf8)
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    }
    let path = url.components(separatedBy: "?")[0]
    for attempt in 1...4 {  // network can lag a minute behind a wake from sleep
        var got: (Data?, URLResponse?, Error?) = (nil, nil, nil)
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { got = ($0, $1, $2); done.signal() }.resume()
        done.wait()
        if let e = got.2 {
            if attempt == 4 { throw Fail("\(method) \(path) -> network error: \(e.localizedDescription)") }
            Thread.sleep(forTimeInterval: 30)
            continue
        }
        let code = (got.1 as? HTTPURLResponse)?.statusCode ?? 0, data = got.0 ?? Data()
        guard (200..<300).contains(code) else {
            throw Fail("\(method) \(path) -> \(code): \(String(decoding: data.prefix(300), as: UTF8.self))")
        }
        return data.isEmpty ? [String: Any]() : try JSONSerialization.jsonObject(with: data)
    }
    throw Fail("unreachable")
}

func appCreds() throws -> (id: String, secret: String) {
    guard let a = secrets.get("app"), let id = a["client_id"] as? String, let secret = a["client_secret"] as? String,
          !id.isEmpty, !secret.isEmpty else { throw notSignedIn }
    return (id, secret)
}

// token endpoint calls; selftest swaps in a fake
var tokenPost: ([String: String]) throws -> Any = { try http("POST", "\(oauth)/token", form: $0) }

func saveTokens(_ t: [String: Any], redirect: String) throws -> String {
    guard let access = t["access_token"] as? String, let refresh = t["refresh_token"] as? String,
          let ttl = t["expires_in"] as? Int else { throw Fail("unexpected token response") }
    try secrets.set("token", ["refresh_token": refresh, "access_token": access,
                              "expires_at": Int(Date().timeIntervalSince1970) + ttl, "redirect_uri": redirect])
    return access
}

func accessToken() throws -> String {
    guard secrets.get("token") != nil else { throw notSignedIn }
    // the app and a `freee in` can get here together; two refreshes of one rotating refresh
    // token would burn it, so take turns and re-read after the wait
    try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
    let fd = open(configDir.appendingPathComponent("token.lock").path, O_CREAT | O_RDWR, 0o600)
    guard fd >= 0 else { throw Fail("cannot open token.lock") }
    defer { close(fd) }
    flock(fd, LOCK_EX)
    let tok = secrets.get("token") ?? [:]
    if let access = tok["access_token"] as? String, let exp = (tok["expires_at"] as? NSNumber)?.doubleValue,
       exp > Date().timeIntervalSince1970 + 300 { return access }
    let (id, secret) = try appCreds()
    let redirect = tok["redirect_uri"] as? String ?? callbackURL
    let t: Any
    do {
        t = try tokenPost(["grant_type": "refresh_token", "client_id": id, "client_secret": secret,
                           "refresh_token": tok["refresh_token"] as? String ?? "", "redirect_uri": redirect])
    } catch {
        throw Fail("freee sign-in expired, sign in again (Settings > Sign out, then Set up): \(error)")
    }
    return try saveTokens(t as? [String: Any] ?? [:], redirect: redirect)
}

struct Conf { let company: Int, employee: Int, name: String, role: String }

func loadConf() throws -> Conf {
    guard let data = try? Data(contentsOf: confURL), let c = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let company = c["company_id"] as? Int, let employee = c["employee_id"] as? Int
    else { throw notSignedIn }
    return Conf(company: company, employee: employee, name: c["company"] as? String ?? "", role: c["role"] as? String ?? "")
}

func saveConf(_ co: [String: Any]) throws {
    try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
    let conf: [String: Any] = ["company_id": co["id"] ?? 0, "employee_id": co["employee_id"] ?? 0,
                               "company": co["name"] ?? "", "role": co["role"] ?? ""]
    try JSONSerialization.data(withJSONObject: conf, options: [.prettyPrinted, .sortedKeys]).write(to: confURL)
}

// keeps the app credentials, so signing in again needs only the browser
func signOut() {
    secrets.delete("token")
    try? FileManager.default.removeItem(at: confURL)
}

func signedIn() -> Conf? { secrets.get("token") == nil ? nil : try? loadConf() }

// the authorization code from freee's redirect -> tokens -> the companies where you are an employee,
// the one picked at freee's company prompt alone when it is among them; blocking, call it off the main thread
func signInCompanies(code: String) throws -> [[String: Any]] {
    let (id, secret) = try appCreds()
    let t = try tokenPost(["grant_type": "authorization_code", "client_id": id, "client_secret": secret,
                           "code": code, "redirect_uri": callbackURL]) as? [String: Any] ?? [:]
    let tok = try saveTokens(t, redirect: callbackURL)
    let me = try http("GET", "\(apiBase)/users/me", token: tok) as? [String: Any] ?? [:]
    let companies = (me["companies"] as? [[String: Any]] ?? []).filter { $0["employee_id"] is Int }
    guard !companies.isEmpty else { throw Fail("no company where you are registered as an employee") }
    let chosen = companies.filter { ($0["id"] as? Int) == (t["company_id"] as? Int) }
    return chosen.isEmpty ? companies : chosen
}

typealias Punch = (type: String, at: Date)

protocol Freee {
    func workRecord(_ day: Date) throws -> [String: Any]
    func available() throws -> (types: [String], baseDate: String)
    func punch(_ type: String, baseDate: String) throws
    func punches(_ day: Date) throws -> [Punch]
}

struct LiveFreee: Freee {
    func get(_ path: String, _ query: String = "") throws -> Any {
        let c = try loadConf()
        return try http("GET", "\(apiBase)/employees/\(c.employee)\(path)?company_id=\(c.company)\(query)", token: accessToken())
    }

    func workRecord(_ day: Date) throws -> [String: Any] { try get("/work_records/\(ymd(day))") as? [String: Any] ?? [:] }

    func available() throws -> (types: [String], baseDate: String) {
        let a = try get("/time_clocks/available_types") as? [String: Any] ?? [:]
        return (a["available_types"] as? [String] ?? [], a["base_date"] as? String ?? "")
    }

    func punch(_ type: String, baseDate: String) throws {
        let c = try loadConf()
        _ = try http("POST", "\(apiBase)/employees/\(c.employee)/time_clocks", token: accessToken(),
                     json: ["company_id": c.company, "type": type, "base_date": baseDate])
    }

    func punches(_ day: Date) throws -> [Punch] {
        let list = try get("/time_clocks", "&from_date=\(ymd(day))&to_date=\(ymd(day))&limit=100")
        return parsePunches(list as? [[String: Any]] ?? [])
    }
}

func parsePunches(_ list: [[String: Any]]) -> [Punch] {
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return list.compactMap { c -> Punch? in
        guard let type = c["type"] as? String, let s = c["datetime"] as? String,
              let d = iso.date(from: s) ?? ISO8601DateFormatter().date(from: s) else { return nil }
        return (type, d)
    }.sorted { $0.at < $1.at }
}

// MARK: - Day rules

let offDays = ["substitute_holiday": "substitute holiday", "compensatory_holiday": "compensatory day off",
               "special_holiday": "special leave"]
let leaveNames = ["annual_paid_holiday": "paid leave", "special_holiday": "special leave",
                  "compensatory_holiday": "compensatory day off"]
let partNames = ["half": "half day", "morning_off": "morning off", "afternoon_off": "afternoon off", "hourly": "hourly"]

// (category, unit) of each leave on the day, from `holidays` and the older `paid_holidays`
func leaves(_ wr: [String: Any]) -> [(cat: String, unit: String)] {
    let h = (wr["holidays"] as? [[String: Any]] ?? []).map { ($0["holiday_category"] as? String ?? "", $0["holiday_type"] as? String ?? "") }
    let p = (wr["paid_holidays"] as? [[String: Any]] ?? []).map { ("annual_paid_holiday", $0["type"] as? String ?? "") }
    return (h + p).map { (cat: $0.0, unit: $0.1) }
}

func workingPattern(_ wr: [String: Any]) -> Bool {
    wr["day_pattern"] as? String == "normal_day"
        || ["substitute_holiday_work", "compensatory_holiday_work"].contains(wr["schedule_pattern"] as? String ?? "")
}

// why today should not be clocked automatically for `kind`, or nil
func dayBlock(_ wr: [String: Any], _ kind: Kind) -> String? {
    let sp = wr["schedule_pattern"] as? String ?? ""
    if offDays[sp] != nil { return "day off (\(sp))" }
    if !workingPattern(wr) { return "not a working day (\(wr["day_pattern"] as? String ?? "?"))" }
    if wr["is_absence"] as? Bool == true { return "marked absent" }
    let units = Set(leaves(wr).map(\.unit))
    if units.contains("full") { return "full-day leave" }
    let partial = units.intersection(kind == .clockIn ? ["half", "hourly", "morning_off"] : ["half", "hourly", "afternoon_off"])
    if !partial.isEmpty { return "partial leave (\(partial.sorted().joined(separator: ", "))), punch by hand" }
    return nil
}

// the day type for the menu: "work day", "holiday", "paid leave", "work day (morning off, paid leave)", ...
func dayLabel(_ wr: [String: Any], _ day: Date) -> String {
    if let off = offDays[wr["schedule_pattern"] as? String ?? ""] { return off }
    if !workingPattern(wr) { return cal.isDateInWeekend(day) ? "weekend" : "holiday" }
    if wr["is_absence"] as? Bool == true { return "absent" }
    let l = leaves(wr)
    if let full = l.first(where: { $0.unit == "full" }) { return leaveNames[full.cat] ?? "leave" }
    if let part = l.first { return "work day (\(partNames[part.unit] ?? part.unit), \(leaveNames[part.cat] ?? "leave"))" }
    return "work day"
}

// MARK: - Scheduler

enum Phase { case checking, counting, waiting, punching, finished }

struct Plan {
    var day: String  // the date it is for; a new date starts over
    var end: Date  // give up after this: the window end, later after a Delay or once late
    var phase = Phase.checking
    var target = Date.distantFuture
    var delayed = false
    var warned = false  // the 30s notice went out
    var late = false  // the window was missed; clocking when the Mac is next used
    var skipped = false
    var active: Bool { phase == .counting || phase == .waiting }
}

enum Outcome { case punched, nothing, notice(String) }

final class Env {  // everything the scheduler touches outside itself; selftest fakes all of it
    var now: () -> Date = { Date() }
    var idle: () -> Double = hidIdleSeconds
    var random: (Double) -> Double = { $0 > 0 ? Double.random(in: 0...$0) : 0 }
    var log: (String) -> Void = logLine
    var notify: (String) -> Void = { logLine($0); osaNotify($0) }
    var freee: Freee = LiveFreee()
    var inline = false  // run freee calls synchronously (selftest)
    let queue = DispatchQueue(label: "freee.api")

    // freee calls block on the network, so they run off the main thread and report back on it
    func api<T>(_ work: @escaping () throws -> T, _ done: @escaping (Result<T, Error>) -> Void) {
        if inline { return done(Result { try work() }) }
        queue.async {
            let r = Result { try work() }
            DispatchQueue.main.async { done(r) }
        }
    }
}

// Decides each clock in/out of the day from the clock, freee and the menu. Nothing is stored: after a restart
// it asks freee again, so a run that was cut off is re-planned (or handled as late or missed after its window).
final class Scheduler {
    let env: Env
    var plans: [Kind: Plan] = [:]
    var demo: (kind: Kind, plan: Plan)?
    var onPunch: () -> Void = {}

    init(_ env: Env) { self.env = env }

    func tick() {
        let now = env.now()
        for kind in Kind.allCases { step(kind, now) }
        if var d = demo {
            let left = d.plan.target.timeIntervalSince(now)
            if left <= 0 {
                demo = nil
                env.notify("Demo: would clock \(d.kind.rawValue) now")
            } else if left <= 30 && !d.plan.warned {
                d.plan.warned = true
                demo = d
                env.notify("Clock \(d.kind.rawValue) in \(Int(left.rounded(.up)))s")
            }
        }
    }

    func step(_ kind: Kind, _ now: Date) {
        guard var p = plans[kind], p.day == ymd(now) else {
            let start = at(now, kind.window.start)
            guard !cal.isDateInWeekend(now), now >= start else { return }
            plans[kind] = Plan(day: ymd(now), end: at(now, kind.window.end))
            return consider(kind, start: start)
        }
        switch p.phase {
        case .counting:
            let left = p.target.timeIntervalSince(now)
            if now >= p.end {
                late(kind, now)  // the Mac slept through the rest of the window
            } else if left <= 0 {
                if env.idle() > idleMax {
                    p.phase = .waiting
                    plans[kind] = p
                } else {
                    punch(kind)
                }
            } else if left <= 30 && !p.warned {
                p.warned = true
                plans[kind] = p
                env.notify("Clock \(kind.rawValue) in \(Int(left.rounded(.up)))s")
            }
        case .waiting:
            if env.idle() <= idleMax {
                if p.late { countdown(kind, now) } else { punch(kind) }
            } else if now >= p.end {
                if kind.late && !p.late && now < lateUntil(kind, now) {
                    p.late = true  // keep waiting past the window
                    p.end = lateUntil(kind, now)
                    plans[kind] = p
                } else {
                    missed(kind)
                }
            }
        default:
            break
        }
    }

    // first look at a clock in/out today: working day? anything to punch? then pick the time
    func consider(_ kind: Kind, start: Date) {
        let freee = env.freee, today = env.now(), name = kind.rawValue
        env.api({ try (freee.workRecord(today), freee.available()) }) { [self] r in
            guard var p = plans[kind], p.phase == .checking else { return }
            let now = env.now()
            switch r {
            case .failure(let e):
                env.notify("auto \(name) failed: \(e)")
                finish(kind)
            case .success(let got):
                let (wr, av) = got
                if let why = dayBlock(wr, kind) {
                    (why.hasSuffix("by hand") ? env.notify : env.log)("auto \(name) skipped: \(why)")
                    finish(kind)
                } else if av.baseDate != ymd(now) {
                    env.notify(openShift(kind, av.baseDate))
                    finish(kind)
                } else if !av.types.contains(kind.type) {
                    env.log("auto \(name): nothing to do, can punch only \(av.types)")
                    finish(kind)
                } else if now >= p.end {
                    late(kind, now)  // the Mac was asleep or off for the whole window
                } else {
                    let lo = max(now, start)
                    p.target = lo + env.random(max(0, p.end.timeIntervalSince(lo) - 60))
                    p.phase = .counting
                    plans[kind] = p
                    env.log("auto \(name): target \(fmt(p.target, "HH:mm:ss"))")
                }
            }
        }
    }

    // the latest a late clock in/out may happen: clock in not once clock out is due, clock out by midnight
    func lateUntil(_ kind: Kind, _ now: Date) -> Date {
        kind == .clockIn ? at(now, Kind.clockOut.window.start) : cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now))!
    }

    // past the window: with the late setting on and still in time, count down 30s from now; else report it
    func late(_ kind: Kind, _ now: Date) {
        guard kind.late, now < lateUntil(kind, now), plans[kind] != nil else { return missed(kind) }
        plans[kind]!.late = true
        plans[kind]!.end = lateUntil(kind, now)
        countdown(kind, now)
    }

    func countdown(_ kind: Kind, _ now: Date) {
        guard var p = plans[kind] else { return }
        p.target = now + 30
        p.warned = true
        p.phase = .counting
        plans[kind] = p
        env.notify("Late clock \(kind.rawValue) in 30s")
    }

    func punch(_ kind: Kind) {
        plans[kind]?.phase = .punching
        let freee = env.freee, today = ymd(env.now()), name = kind.rawValue
        env.api({ () throws -> Outcome in
            let av = try freee.available()
            if av.baseDate != today { return .notice(openShift(kind, av.baseDate)) }
            if !av.types.contains(kind.type) { return .nothing }  // punched by hand meanwhile
            try freee.punch(kind.type, baseDate: av.baseDate)
            return .punched
        }) { [self] r in
            switch r {
            case .success(.punched):
                env.notify("Clocked \(name) at \(fmt(env.now(), "HH:mm"))")
                onPunch()
            case .success(.nothing): env.log("auto \(name): nothing to do, already punched")
            case .success(.notice(let msg)): env.notify(msg)
            case .failure(let e): env.notify("auto \(name) failed: \(e)")
            }
            finish(kind)
        }
    }

    func finish(_ kind: Kind) { plans[kind]?.phase = .finished }

    func missed(_ kind: Kind) {
        env.notify("Not clocked \(kind.rawValue): Mac was asleep, off or idle \(hm(kind.window.start))-\(hm(kind.window.end)). "
                   + "Run `freee \(kind.rawValue)` if needed")
        finish(kind)
    }

    // after new settings or a sign-in: plan today again, except what is under way or was skipped
    func replan() {
        for (kind, p) in plans where p.phase != .waiting && p.phase != .punching && !p.skipped {
            plans[kind] = nil
        }
    }

    // Clock now / Delay 10 min / Skip from the menu, applied to what the menu shows
    func act(_ action: String) {
        if var d = demo {
            env.log("demo: \(action) from the menu bar")
            switch action {
            case "delay":
                d.plan.target += delayStep
                d.plan.delayed = true
                d.plan.warned = false
                demo = d
            case "now":
                demo = nil
                env.notify("Demo: would clock \(d.kind.rawValue) now")
            default:
                demo = nil
            }
            return
        }
        guard let kind = Kind.allCases.first(where: { plans[$0]?.active == true }), var p = plans[kind] else { return }
        env.log("auto \(kind.rawValue): \(action) from the menu bar")
        switch action {
        case "now":
            punch(kind)
        case "delay" where p.phase == .counting:
            p.target += delayStep
            p.end = max(p.end, p.target + 60)
            p.delayed = true
            p.warned = false
            plans[kind] = p
        case "skip":
            plans[kind]?.skipped = true
            finish(kind)
        default:
            break
        }
    }

    // what the menu shows under the separator: the demo, or a clock in/out within 30s, waiting or punching
    func pending(_ now: Date) -> (kind: Kind, plan: Plan, demo: Bool)? {
        if let d = demo { return (d.kind, d.plan, true) }
        for kind in Kind.allCases {
            guard let p = plans[kind] else { continue }
            if p.phase == .waiting || p.phase == .punching
                || (p.phase == .counting && (p.delayed || p.target.timeIntervalSince(now) <= showWithin)) {
                return (kind, p, false)
            }
        }
        return nil
    }

    // something to show or do within seconds: the menu bar ticks every second then
    func soon(_ now: Date) -> Bool {
        pending(now) != nil
            || plans.values.contains { $0.phase == .counting && $0.target.timeIntervalSince(now) <= showWithin + 5 }
    }

    func startDemo(_ kind: Kind) {
        if Kind.allCases.contains(where: { plans[$0]?.active == true }) {
            return env.notify("Demo not started: a real clock in/out is counting down")
        }
        var p = Plan(day: "", end: .distantFuture)
        p.phase = .counting
        p.target = env.now() + 40
        demo = (kind, p)
        env.log("demo \(kind.rawValue): 40s countdown")
    }
}

// MARK: - Sign in

// what freee's redirect to the callback says: the code, an error, or nil when the request is not the callback
func callbackResult(_ target: String, state: String) -> Result<String, Error>? {
    guard let q = URLComponents(string: "http://127.0.0.1\(target)"), q.path == "/callback" else { return nil }
    let item = { (name: String) in q.queryItems?.first { $0.name == name }?.value }
    if item("state") != state { return .failure(Fail("the browser answer was for another sign-in, try again")) }
    if let code = item("code"), !code.isEmpty { return .success(code) }
    return .failure(Fail("freee: \(item("error_description") ?? item("error") ?? "no code")"))
}

// one browser sign-in: opens freee's consent page and catches its redirect on 127.0.0.1
final class SignIn {
    let state = UUID().uuidString
    var listener: NWListener?
    var done: (Result<String, Error>) -> Void = { _ in }

    func start(clientID: String) throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: callbackPort)!)
        params.allowLocalEndpointReuse = true
        let l = try NWListener(using: params)
        l.newConnectionHandler = { [weak self] c in self?.serve(c) }
        l.stateUpdateHandler = { [weak self] s in
            if case .failed(let e) = s { self?.finish(.failure(Fail("cannot listen on \(callbackURL): \(e)"))) }
        }
        l.start(queue: .main)
        listener = l
        var c = URLComponents(string: "\(oauth)/authorize")!
        c.queryItems = [.init(name: "client_id", value: clientID), .init(name: "redirect_uri", value: callbackURL),
                        .init(name: "response_type", value: "code"), .init(name: "prompt", value: "select_company"),
                        .init(name: "state", value: state)]
        NSWorkspace.shared.open(c.url!)
    }

    func serve(_ c: NWConnection) {
        c.start(queue: .main)
        c.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, _, _ in
            let head = String(decoding: data ?? Data(), as: UTF8.self).components(separatedBy: "\r\n").first ?? ""
            let parts = head.split(separator: " ")
            let result = self.flatMap { s in callbackResult(parts.count > 1 ? String(parts[1]) : "", state: s.state) }
            let ok = (try? result?.get()) != nil
            let body = result == nil ? "Not found" : ok ? "Signed in to freee clock. You can close this tab."
                : "Sign-in failed. Go back to freee clock to try again."
            let resp = "HTTP/1.1 \(result == nil ? "404 Not Found" : "200 OK")\r\nContent-Type: text/plain; charset=utf-8\r\n"
                + "Content-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            c.send(content: Data(resp.utf8), completion: .contentProcessed { _ in c.cancel() })
            if let result { self?.finish(result) }
        }
    }

    func finish(_ r: Result<String, Error>) {
        cancel()
        let d = done
        done = { _ in }
        d(r)
    }

    func cancel() {
        listener?.cancel()
        listener = nil
    }
}

// MARK: - Windows

func label(_ text: String, small: Bool = false, width: CGFloat? = nil) -> NSTextField {
    let l = width == nil ? NSTextField(labelWithString: text) : NSTextField(wrappingLabelWithString: text)
    if let width { l.preferredMaxLayoutWidth = width }
    if small {
        l.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        l.textColor = .secondaryLabelColor
    }
    return l
}

final class Button: NSButton {
    var onClick: () -> Void = {}

    convenience init(_ title: String, _ onClick: @escaping () -> Void) {
        self.init(frame: .zero)
        self.title = title
        bezelStyle = .rounded
        self.onClick = onClick
        target = self
        action = #selector(clicked)
    }

    @objc func clicked() { onClick() }
}

func stack(_ views: [NSView], vertical: Bool = true, spacing: CGFloat = 8) -> NSStackView {
    let s = NSStackView(views: views)
    s.orientation = vertical ? .vertical : .horizontal
    s.alignment = vertical ? .leading : .centerY
    s.spacing = spacing
    return s
}

// a row with the buttons on the right, as wide as `parent`
func buttonRow(_ buttons: [NSButton], in parent: NSStackView) -> NSStackView {
    let row = NSStackView()
    for b in buttons { row.addView(b, in: .trailing) }
    parent.addArrangedSubview(row)
    row.widthAnchor.constraint(equalTo: parent.widthAnchor).isActive = true
    return row
}

func makeWindow(_ title: String, _ content: NSView, delegate: NSWindowDelegate? = nil) -> NSWindow {
    let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 200), styleMask: [.titled, .closable],
                     backing: .buffered, defer: false)
    w.title = title
    w.isReleasedWhenClosed = false
    w.delegate = delegate
    let v = NSView()
    content.translatesAutoresizingMaskIntoConstraints = false
    v.addSubview(content)
    NSLayoutConstraint.activate([
        content.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 20),
        content.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -20),
        content.topAnchor.constraint(equalTo: v.topAnchor, constant: 20),
        content.bottomAnchor.constraint(equalTo: v.bottomAnchor, constant: -20)])
    w.contentView = v
    return w
}

func present(_ w: NSWindow) {
    w.contentView?.layoutSubtreeIfNeeded()
    if let size = w.contentView?.fittingSize { w.setContentSize(size) }
    if !w.isVisible { w.center() }
    NSApp.activate(ignoringOtherApps: true)
    w.makeKeyAndOrderFront(nil)
}

func timePicker() -> NSDatePicker {
    let p = NSDatePicker()
    p.datePickerStyle = .textFieldAndStepper
    p.datePickerElements = .hourMinute
    p.locale = Locale(identifier: "en_GB")  // 24-hour
    return p
}

// an accessory app has no menu bar of its own, but text fields need Edit for copy and paste shortcuts
func editMenu() -> NSMenu {
    let main = NSMenu(), top = NSMenuItem(), edit = NSMenu(title: "Edit")
    for (title, sel, key) in [("Undo", "undo:", "z"), ("Cut", "cut:", "x"), ("Copy", "copy:", "c"), ("Paste", "paste:", "v"),
                              ("Select All", "selectAll:", "a"), ("Close Window", "performClose:", "w")] {
        edit.addItem(NSMenuItem(title: title, action: Selector(sel), keyEquivalent: key))
    }
    top.submenu = edit
    main.addItem(top)
    return main
}

final class SettingsWindow: NSObject {
    var window: NSWindow!
    let pickers = (0..<4).map { _ in timePicker() }
    let lateIn = NSButton(checkboxWithTitle: "Clock in late", target: nil, action: nil)
    let lateOut = NSButton(checkboxWithTitle: "Clock out late", target: nil, action: nil)
    let problem = label("")
    let account = label("")
    var accountButton: Button!
    var onSave: () -> Void = {}
    var onSetup: () -> Void = {}
    var onSignOut: () -> Void = {}

    override init() {
        super.init()
        problem.textColor = .systemRed
        accountButton = Button("") { [weak self] in self?.accountAction() }
        let grid = NSGridView(views: [[NSGridCell.emptyContentView, label("Start"), label("End")],
                                      [label("Clock in"), pickers[0], pickers[1]],
                                      [label("Clock out"), pickers[2], pickers[3]]])
        grid.rowSpacing = 8
        grid.columnSpacing = 12
        let note = label("Each working day it clocks at a random time inside the window. Late: when the Mac was off, "
                         + "asleep or away for the whole window, it clocks the next time the Mac is used, after a 30s "
                         + "countdown (clock in: until clock out starts; clock out: until midnight).", small: true, width: 360)
        let line = NSBox()
        line.boxType = .separator
        let s = stack([stack([account, accountButton], vertical: false), line, grid, lateIn, lateOut, note, problem], spacing: 12)
        line.widthAnchor.constraint(equalTo: s.widthAnchor).isActive = true
        let cancel = Button("Cancel") { [weak self] in self?.window.close() }
        cancel.keyEquivalent = "\u{1b}"
        let save = Button("Save") { [weak self] in self?.save() }
        save.keyEquivalent = "\r"
        _ = buttonRow([cancel, save], in: s)
        window = makeWindow("freee clock settings", s)
    }

    func show() {
        for (p, t) in zip(pickers, [settings.inStart, settings.inEnd, settings.outStart, settings.outEnd]) {
            p.dateValue = at(Date(), t)
        }
        lateIn.state = settings.lateIn ? .on : .off
        lateOut.state = settings.lateOut ? .on : .off
        problem.stringValue = ""
        loadAccount()
        present(window)
    }

    func loadAccount() {
        if let c = signedIn() {
            account.stringValue = "Signed in: \(c.name) (employee \(c.employee))"
            accountButton.title = "Sign out"
        } else {
            account.stringValue = "Not signed in to freee"
            accountButton.title = "Set up..."
        }
    }

    func accountAction() {
        guard signedIn() != nil else { return onSetup() }
        let a = NSAlert()
        a.messageText = "Sign out of freee?"
        a.informativeText = "Automatic clock in and out stop until you sign in again."
        a.addButton(withTitle: "Sign out")
        a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        signOut()
        loadAccount()
        onSignOut()
    }

    func save() {
        func read(_ p: NSDatePicker) -> HM {
            let c = cal.dateComponents([.hour, .minute], from: p.dateValue)
            return (h: c.hour ?? 0, m: c.minute ?? 0)
        }
        var s = settings
        (s.inStart, s.inEnd, s.outStart, s.outEnd) = (read(pickers[0]), read(pickers[1]), read(pickers[2]), read(pickers[3]))
        s.lateIn = lateIn.state == .on
        s.lateOut = lateOut.state == .on
        if let why = s.problem { return problem.stringValue = why }
        do { try saveSettings(s) } catch { return problem.stringValue = "\(error)" }
        settings = s
        window.close()
        onSave()
    }
}

final class SetupWindow: NSObject, NSWindowDelegate {
    var window: NSWindow!
    let clientID = NSTextField(string: "")
    let clientSecret = NSSecureTextField(string: "")
    let state = label("", small: true, width: 380)
    var signInButton: Button!
    var flow: SignIn?
    var onDone: () -> Void = {}

    override init() {
        super.init()
        let callback = NSTextField(string: callbackURL)
        callback.isEditable = false
        callback.isSelectable = true
        for f in [callback, clientID, clientSecret] { f.widthAnchor.constraint(equalToConstant: 280).isActive = true }
        let open = Button("Open freee developers page") { NSWorkspace.shared.open(URL(string: appsPage)!) }
        let copy = Button("Copy") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(callbackURL, forType: .string)
        }
        let grid = NSGridView(views: [[label("Client ID"), clientID], [label("Client Secret"), clientSecret]])
        grid.rowSpacing = 8
        signInButton = Button("Sign in with freee") { [weak self] in self?.signIn() }
        signInButton.keyEquivalent = "\r"
        let s = stack([
            label("freee clock signs in through your own freee app, so no one else holds a key to your account.", width: 380),
            label("1. Create an app on the freee developers page (free). Set its callback URL to the address below "
                  + "and give it the 人事労務 (HR) permissions for work records and time clocks.", width: 380),
            open,
            stack([callback, copy], vertical: false),
            label("2. Paste the app's Client ID and Client Secret, then sign in. They and the sign-in are kept in "
                  + "your login Keychain.", width: 380),
            grid,
            signInButton,
            state,
        ], spacing: 10)
        window = makeWindow("Sign in to freee", s, delegate: self)
    }

    func show() {
        let saved = secrets.get("app")
        clientID.stringValue = saved?["client_id"] as? String ?? ""
        clientSecret.stringValue = ""
        clientSecret.placeholderString = saved == nil ? "" : "saved; leave empty to keep it"
        say("")
        signInButton.isEnabled = true
        present(window)
    }

    func say(_ text: String) { state.stringValue = text }

    func windowWillClose(_ notification: Notification) {
        flow?.cancel()
        flow = nil
    }

    func signIn() {
        let id = clientID.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        var secret = clientSecret.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if secret.isEmpty, let saved = secrets.get("app"), saved["client_id"] as? String == id {
            secret = saved["client_secret"] as? String ?? ""
        }
        guard !id.isEmpty, !secret.isEmpty else { return say("Paste the Client ID and Client Secret first.") }
        do { try secrets.set("app", ["client_id": id, "client_secret": secret]) } catch { return say("\(error)") }
        flow?.cancel()
        let f = SignIn()
        f.done = { [weak self] r in self?.answered(r) }
        do { try f.start(clientID: id) } catch { return say("\(error)") }
        flow = f
        say("Allow access in the browser that just opened...")
    }

    func answered(_ r: Result<String, Error>) {
        flow = nil
        switch r {
        case .failure(let e):
            say("\(e)")
        case .success(let code):
            say("Signing in...")
            signInButton.isEnabled = false
            DispatchQueue.global().async {
                let r = Result { try signInCompanies(code: code) }
                DispatchQueue.main.async { [weak self] in self?.chooseCompany(r) }
            }
        }
    }

    func chooseCompany(_ r: Result<[[String: Any]], Error>) {
        signInButton.isEnabled = true
        let list: [[String: Any]]
        switch r {
        case .failure(let e): return say("\(e)")
        case .success(let l): list = l
        }
        var co = list[0]
        if list.count > 1 {
            let a = NSAlert()
            a.messageText = "Which company?"
            let pop = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 280, height: 26))
            for (i, c) in list.enumerated() { pop.addItem(withTitle: "\(i + 1). \(c["display_name"] ?? c["name"] ?? "")") }
            a.accessoryView = pop
            a.addButton(withTitle: "OK")
            a.addButton(withTitle: "Cancel")
            guard a.runModal() == .alertFirstButtonReturn else { return say("No company chosen; sign in again.") }
            co = list[pop.indexOfSelectedItem]
        }
        do { try saveConf(co) } catch { return say("\(error)") }
        window.close()
        onDone()
    }
}

// MARK: - Menu bar

let menuFont = NSFont.menuFont(ofSize: 0)
let digits = NSFont.monospacedDigitSystemFont(ofSize: menuFont.pointSize, weight: .regular)
let punchNames: [String: (String, NSColor)] = [
    "clock_in": ("Clocked in", .systemGreen), "break_end": ("Back from break", .systemGreen),
    "break_begin": ("On break", .systemOrange), "clock_out": ("Clocked out", .systemGray)]
let tabbed: NSParagraphStyle = {  // lines up the times after the punch names
    let p = NSMutableParagraphStyle()
    p.tabStops = [NSTextTab(textAlignment: .left, location: 130)]
    return p
}()

func mmss(_ s: Int) -> String { String(format: "%02d:%02d", s / 60, s % 60) }

// a menu line with a dot in front; a clear dot keeps lines without one aligned
func line(_ text: String, dot: NSColor = .clear, font: NSFont = menuFont) -> NSAttributedString {
    let s = NSMutableAttributedString(string: "● ", attributes: [.font: font, .foregroundColor: dot])
    s.append(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.labelColor]))
    s.addAttribute(.paragraphStyle, value: tabbed, range: NSRange(location: 0, length: s.length))
    return s
}

// an information line in the menu: a plain label in a custom view, so it is neither greyed out
// (as a disabled item would be) nor highlighted on hover (as an enabled one would be)
final class InfoLine {
    let item = NSMenuItem()
    let label = NSTextField(labelWithString: "")

    init() {
        let v = NSView()
        v.autoresizingMask = [.width]
        label.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -14),
            label.topAnchor.constraint(equalTo: v.topAnchor, constant: 3),
            label.bottomAnchor.constraint(equalTo: v.bottomAnchor, constant: -3)])
        item.view = v
    }

    func set(_ text: NSAttributedString) {
        guard let v = item.view, label.attributedStringValue != text else { return }
        label.attributedStringValue = text
        v.setFrameSize(v.fittingSize)
    }
}

struct Status {
    var day = ""  // the date it is for; a new date starts empty
    var label: String?
    var punches: [Punch] = []
    var error: String?
    var loaded = false
    var updated = Date.distantPast
}

final class Bar: NSObject, NSMenuDelegate {
    let env: Env
    let scheduler: Scheduler
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    let menu = NSMenu()
    let today = InfoLine(), sep = NSMenuItem.separator(), pending = InfoLine()
    var punchLines: [InfoLine] = []
    let actions = [("Clock now", "now"), ("Delay 10 min", "delay"), ("Skip", "skip")].map { title, action in
        let m = NSMenuItem(title: title, action: #selector(Bar.act(_:)), keyEquivalent: "")
        m.representedObject = action
        return m
    }
    let settingsItem = NSMenuItem(title: "Settings...", action: #selector(Bar.openSettings), keyEquivalent: ",")
    let settingsWindow = SettingsWindow()
    let setupWindow = SetupWindow()
    let icon = NSImage(systemSymbolName: "clock", accessibilityDescription: "freee clock")
    let iconLit = NSImage(systemSymbolName: "clock.fill", accessibilityDescription: "freee clock")
    var lit = false
    var status = Status()
    var refreshing = false

    override init() {
        let env = Env()
        self.env = env
        scheduler = Scheduler(env)
        super.init()
        menu.autoenablesItems = false
        for m in [today.item, sep, pending.item] + actions + [NSMenuItem.separator(), settingsItem] { menu.addItem(m) }
        for m in actions + [settingsItem] { m.target = self }
        menu.delegate = self
        item.menu = menu
        item.button?.image = icon
        scheduler.onPunch = { [weak self] in self?.refresh() }
        settingsWindow.onSave = { [weak self] in self?.changed("settings: \(settings.summary)") }
        settingsWindow.onSetup = { [weak self] in self?.setupWindow.show() }
        settingsWindow.onSignOut = { [weak self] in self?.changed("signed out") }
        setupWindow.onDone = { [weak self] in self?.changed("signed in") }
        tick()
        next()
        RunLoop.main.add(Timer(timeInterval: 600, repeats: true) { [weak self] _ in self?.refresh() }, forMode: .common)
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in self?.refresh() }
        // from the command line: `freee in/out` asks for a refresh, `freee demo` starts a demo, `freee setup` opens Setup
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(forName: .init("local.freee-clock.refresh"), object: nil, queue: .main) { [weak self] _ in self?.refresh() }
        dnc.addObserver(forName: .init("local.freee-clock.demo"), object: nil, queue: .main) { [weak self] n in
            self?.scheduler.startDemo(Kind(rawValue: n.object as? String ?? "") ?? .clockIn)
        }
        dnc.addObserver(forName: .init("local.freee-clock.setup"), object: nil, queue: .main) { [weak self] _ in
            self?.setupWindow.show()
        }
        logLine("menu bar app started; \(settings.summary)")
        if signedIn() == nil { setupWindow.show() }
    }

    // 5s at rest; every second while a countdown is near or showing
    func next() {
        let every = scheduler.soon(Date()) ? 1.0 : 5.0
        RunLoop.main.add(Timer(timeInterval: every, repeats: false) { [weak self] _ in
            self?.tick()
            self?.next()
        }, forMode: .common)  // .common: keep counting while the menu is open
    }

    // after a sign-in, sign-out or new settings: show and plan today afresh
    func changed(_ what: String) {
        logLine(what)
        scheduler.replan()
        status = Status(day: ymd(Date()))
        refresh()
        tick()
    }

    // ask freee for today's status lines in the background
    func refresh() {
        if refreshing { return }
        refreshing = true
        let freee = env.freee, now = Date()
        env.api({ try (dayLabel(freee.workRecord(now), now), freee.punches(now)) }) { [self] r in
            refreshing = false
            guard status.day == ymd(now) else { return refresh() }  // the day turned meanwhile
            status.loaded = true
            status.updated = Date()
            switch r {
            case .success(let got):
                status.label = got.0
                status.punches = got.1
                status.error = nil
            case .failure(let e):
                status.error = "\(e)"
            }
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        if Date().timeIntervalSince(status.updated) > 120 { refresh() }
        tick()
    }

    // today's punch lines under the day line, one menu item each
    func showLines(_ texts: [NSAttributedString]) {
        while punchLines.count < texts.count {
            let l = InfoLine()
            menu.insertItem(l.item, at: 1 + punchLines.count)
            punchLines.append(l)
        }
        for (i, l) in punchLines.enumerated() {
            l.item.isHidden = i >= texts.count
            if i < texts.count { l.set(texts[i]) }
        }
    }

    func tick() {
        let now = Date()
        scheduler.tick()
        if status.day != ymd(now) {
            status = Status(day: ymd(now))
            refresh()
        }
        today.set(line("\(fmt(now, "MM-dd")): \(status.label ?? "...")"))
        if let err = status.error {
            showLines([line("freee: \(err.prefix(70))", dot: .systemOrange)])
        } else if !status.loaded || status.punches.isEmpty {
            showLines([line(status.loaded ? "No punches today" : "Loading...", dot: .systemGray)])
        } else {
            showLines(status.punches.map { p in
                let (name, colour) = punchNames[p.type] ?? (p.type, .systemGray)
                return line("\(name)\t\(fmt(p.at, "HH:mm"))", dot: colour)
            })
        }

        let p = scheduler.pending(now)
        var text = "", acting = false, waiting = false
        if let p {
            let verb = (p.demo ? "Demo: " : "") + (p.kind == .clockIn ? "Clocking in" : "Clocking out")
            let left = Int(p.plan.target.timeIntervalSince(now))
            switch p.plan.phase {
            case .waiting:
                text = "\(verb): waiting for you"
                acting = true
                waiting = true
            case .counting where left > 0:
                text = "\(verb) \(mmss(left))"
                acting = true
            default:
                text = "\(verb)..."
            }
        }
        pending.set(line(text, dot: .systemRed, font: digits))
        sep.isHidden = p == nil
        pending.item.isHidden = p == nil
        for m in actions {  // no Delay while it waits for you
            m.isHidden = !acting || (waiting && m.representedObject as? String == "delay")
        }
        lit = p != nil && !lit
        item.button?.image = lit ? iconLit : icon
        item.button?.contentTintColor = lit ? .systemRed : nil
    }

    @objc func act(_ sender: NSMenuItem) {
        if let action = sender.representedObject as? String { scheduler.act(action) }
    }

    @objc func openSettings() { settingsWindow.show() }
}

// MARK: - Command line

func post(_ name: String, _ object: String? = nil) {
    DistributedNotificationCenter.default().postNotificationName(
        .init("local.freee-clock.\(name)"), object: object, userInfo: nil, deliverImmediately: true)
}

func cliStatus() throws {
    let c = try loadConf(), f = LiveFreee(), now = Date()
    let wr = try f.workRecord(now), av = try f.available()
    print("\(c.name): employee \(c.employee), role \(c.role)")
    print("today \(ymd(now)): day_pattern=\(wr["day_pattern"] ?? "-") schedule_pattern='\(wr["schedule_pattern"] ?? "")'")
    print("can punch now: \(av.types.isEmpty ? "nothing" : av.types.joined(separator: ", ")) (base_date \(av.baseDate))")
    for kind in Kind.allCases { print("auto \(kind.rawValue) today: \(dayBlock(wr, kind) ?? "yes")") }
    print("Mac idle: \(Int(hidIdleSeconds()))s (auto waits while > \(Int(idleMax))s)")
    let punches = try f.punches(now).map { "\($0.type) \(fmt($0.at, "HH:mm"))" }
    print("menu: \(fmt(now, "MM-dd")): \(dayLabel(wr, now)); \(punches.isEmpty ? "no punches today" : punches.joined(separator: ", "))")
    print("settings: \(settings.summary)")
}

func cliPunch(_ kind: Kind) throws {
    let f = LiveFreee()
    // no available_types gate: freee accepts a later clock_out over an earlier one, let the API decide
    try f.punch(kind.type, baseDate: f.available().baseDate)
    let msg = "Clocked \(kind.rawValue) at \(fmt(Date(), "HH:mm"))"
    print(msg)
    osaNotify(msg)
    post("refresh")
}

// MARK: - Selftest

final class FakeFreee: Freee {
    var record: [String: Any] = ["day_pattern": "normal_day", "schedule_pattern": ""]
    var types = ["clock_in"]
    var base: String?  // nil: today
    var punched: [String] = []
    let now: () -> Date
    init(now: @escaping () -> Date) { self.now = now }
    func workRecord(_ day: Date) throws -> [String: Any] { record }
    func available() throws -> (types: [String], baseDate: String) { (types, base ?? ymd(now())) }
    func punch(_ type: String, baseDate: String) throws { punched.append(type) }
    func punches(_ day: Date) throws -> [Punch] { [] }
}

func selftest() -> Bool {
    var bad = 0
    func check(_ ok: Bool, _ what: String) {
        print(ok ? "ok " : "BAD", what)
        if !ok { bad += 1 }
    }
    let normal: [String: Any] = ["day_pattern": "normal_day", "schedule_pattern": ""]
    func with(_ extra: [String: Any]) -> [String: Any] { normal.merging(extra) { $1 } }
    let paidFull = with(["holidays": [["holiday_category": "annual_paid_holiday", "holiday_type": "full"]]])
    let monday = cal.date(from: DateComponents(year: 2026, month: 11, day: 2))!
    let saturday = cal.date(from: DateComponents(year: 2026, month: 11, day: 7))!

    let blocks: [([String: Any], Kind, String?)] = [
        (normal, .clockIn, nil), (normal, .clockOut, nil),
        (["day_pattern": "prescribed_holiday"], .clockIn, "not a working day"),
        (["day_pattern": "prescribed_holiday", "schedule_pattern": "substitute_holiday_work"], .clockIn, nil),
        (with(["schedule_pattern": "compensatory_holiday"]), .clockIn, "day off"),
        (with(["is_absence": true]), .clockOut, "marked absent"),
        (paidFull, .clockIn, "full-day leave"),
        (with(["holidays": [["holiday_type": "morning_off"]]]), .clockIn, "by hand"),
        (with(["holidays": [["holiday_type": "morning_off"]]]), .clockOut, nil),
        (with(["paid_holidays": [["type": "afternoon_off"]]]), .clockOut, "by hand"),
        (with(["paid_holidays": [["type": "afternoon_off"]]]), .clockIn, nil),
    ]
    for (wr, kind, want) in blocks {
        let got = dayBlock(wr, kind)
        check(want.map { got?.contains($0) == true } ?? (got == nil), "dayBlock \(kind.rawValue) -> \(got ?? "nil")")
    }

    let labels: [([String: Any], Date, String)] = [
        (normal, monday, "work day"), (["day_pattern": "prescribed_holiday"], monday, "holiday"),
        (["day_pattern": "legal_holiday"], saturday, "weekend"),
        (with(["schedule_pattern": "substitute_holiday"]), monday, "substitute holiday"),
        (paidFull, monday, "paid leave"),
        (with(["holidays": [["holiday_category": "special_holiday", "holiday_type": "full"]]]), monday, "special leave"),
        (with(["paid_holidays": [["type": "morning_off"]]]), monday, "work day (morning off, paid leave)"),
        (with(["is_absence": true]), monday, "absent"),
        (["day_pattern": "legal_holiday", "schedule_pattern": "substitute_holiday_work"], saturday, "work day"),
    ]
    for (wr, day, want) in labels { check(dayLabel(wr, day) == want, "dayLabel \(want)") }

    let ps = parsePunches([["type": "clock_out", "datetime": "2026-11-04T18:20:00.000+09:00"],
                           ["type": "clock_in", "datetime": "2026-11-04T08:58:00.000+09:00"],
                           ["type": "break_end", "datetime": "2026-11-04T13:00:00.000+09:00"]])
    check(ps.map(\.type) == ["clock_in", "break_end", "clock_out"] && ps.last?.at.timeIntervalSince1970 == 1793784000,
          "punches in time order")
    check(parsePunches([]).isEmpty, "no punches -> empty")

    var st = Settings(json: ["clock_in_start": "09:30", "clock_in_end": "10:00", "late_clock_out": true, "clock_out_end": "25:00"])
    check(mins(st.inStart) == 570 && mins(st.inEnd) == 600 && st.lateIn && st.lateOut && mins(st.outEnd) == 19 * 60,
          "settings parsed, bad values fall back to defaults")
    let back = Settings(json: st.json)
    check(mins(back.inStart) == 570 && mins(back.outStart) == 18 * 60 && back.lateOut, "settings round trip")
    check(Settings().problem == nil, "default settings are valid")
    st.inEnd = (h: 18, m: 30)
    check(st.problem != nil, "clock in overlapping clock out refused")
    st = Settings()
    st.outEnd = st.outStart
    check(st.problem != nil, "empty window refused")

    // the scheduler on a fake clock, one tick per second
    func run(_ name: String, on day: Date? = nil, from start: HM, fraction: Double = 0.5, ticks: Int = 4000,
             late: Bool = false, setup: (inout Settings) -> Void = { _ in },
             idle: @escaping (Int) -> Double = { _ in 0 }, tweak: (FakeFreee) -> Void = { _ in },
             script: [Int: String] = [:], sleeps: [Int: Double] = [:]) -> (events: [String], punched: [String], shown: Double?) {
        settings = Settings()
        settings.lateIn = late
        settings.lateOut = late
        setup(&settings)
        var now = at(day ?? monday, start), i = 0
        var events: [String] = [], shown: Double?
        let env = Env()
        env.inline = true
        env.now = { now }
        env.idle = { idle(i) }
        env.random = { $0 * fraction }
        env.log = { events.append("log    \($0)") }
        env.notify = { events.append("notify \($0)") }
        let fake = FakeFreee(now: { now })
        tweak(fake)
        env.freee = fake
        let s = Scheduler(env)
        while i < ticks {
            if let a = script[i] { a == "demo" ? s.startDemo(.clockIn) : s.act(a) }
            if let z = sleeps[i] { now += z }
            s.tick()
            if shown == nil, let p = s.pending(now), !p.demo { shown = p.plan.target.timeIntervalSince(now) }
            now += 1
            i += 1
        }
        print("  \(name):")
        for e in events { print("    \(e)") }
        print("    punched \(fake.punched)")
        return (events, fake.punched, shown)
    }
    func has(_ events: [String], _ text: String) -> Bool { events.contains { $0.contains(text) } }

    var r = run("normal clock in", from: (8, 15))
    check(r.punched == ["clock_in"] && has(r.events, "Clock in in 30s") && has(r.events, "Clocked in at 08:37"),
          "clocks in at a random time, notice 30s before")
    check(r.shown == 30, "countdown shows in the last 30s")
    r = run("idle through the window", from: (8, 15), idle: { _ in 9999 })
    check(r.punched.isEmpty && has(r.events, "Not clocked in"), "idle all window: no punch, notice")
    r = run("back at the Mac while it waits", from: (8, 15), idle: { $0 < 1500 ? 9999 : 0 })
    check(r.punched == ["clock_in"] && has(r.events, "Clocked in at 08:40"), "waits for you, then clocks in")
    r = run("first awake after the window", from: (10, 0), ticks: 5)
    check(r.punched.isEmpty && has(r.events, "Not clocked in"), "missed window: notice")
    r = run("first awake after the window, clocked in by hand", from: (10, 0), ticks: 5, tweak: { $0.types = ["clock_out"] })
    check(r.punched.isEmpty && !has(r.events, "notify"), "missed window but already clocked in: quiet")
    r = run("yesterday's shift still open", from: (8, 15), ticks: 10, tweak: { $0.base = "2026-11-01"; $0.types = ["clock_out"] })
    check(r.punched.isEmpty && has(r.events, "shift is still open"), "open shift: notice, no punch")
    r = run("skip from the menu", from: (8, 15), script: [100: "skip"])
    check(r.punched.isEmpty && has(r.events, "skip from the menu bar"), "skip")
    r = run("delay twice near the window end", from: (8, 15), fraction: 1, script: [2620: "delay", 2630: "delay"])
    check(r.punched == ["clock_in"] && has(r.events, "Clocked in at 09:19"), "delays can run past the window")
    r = run("clock now from the menu", from: (8, 15), script: [10: "now"])
    check(r.punched == ["clock_in"] && has(r.events, "Clocked in at 08:15") && !has(r.events, "in 30s"), "clock now")
    r = run("paid leave", from: (8, 15), ticks: 10, tweak: { $0.record = paidFull })
    check(r.punched.isEmpty && has(r.events, "full-day leave") && !has(r.events, "notify"), "paid leave: quiet skip")
    r = run("morning off", from: (8, 15), ticks: 10, tweak: { $0.record = with(["paid_holidays": [["type": "morning_off"]]]) })
    check(r.punched.isEmpty && has(r.events, "notify auto in skipped: partial leave"), "morning off: punch by hand")
    r = run("weekend", on: saturday, from: (8, 15), ticks: 10)
    check(r.punched.isEmpty && r.events.isEmpty, "weekend: nothing")
    r = run("Mac sleeps through the rest of the window", from: (8, 15), sleeps: [600: 3600])
    check(r.punched.isEmpty && has(r.events, "Not clocked in"), "slept past the window: notice")
    r = run("clock out", from: (18, 0), tweak: { $0.types = ["clock_out", "break_begin"] })
    check(r.punched == ["clock_out"] && has(r.events, "Clocked out at 18:") && !has(r.events, "Not clocked in"),
          "clock out; the morning slot stays quiet once clocked in")
    r = run("custom window 09:30-10:00", from: (9, 0), setup: { $0.inStart = (h: 9, m: 30); $0.inEnd = (h: 10, m: 0) })
    check(r.punched == ["clock_in"] && has(r.events, "Clocked in at 09:44"), "clock in window from settings")
    r = run("late: first awake after the window", from: (10, 0), ticks: 60, late: true)
    check(r.punched == ["clock_in"] && has(r.events, "Late clock in in 30s") && has(r.events, "Clocked in at 10:00"),
          "late: clocks in after a 30s countdown")
    r = run("late: clocked in by hand already", from: (10, 0), ticks: 60, late: true, tweak: { $0.types = ["clock_out"] })
    check(r.punched.isEmpty && !has(r.events, "notify"), "late but already clocked in: quiet")
    r = run("late: too late, clock out is due", from: (18, 30), ticks: 10, late: true)
    check(r.punched.isEmpty && has(r.events, "Not clocked in"), "late clock in stops once clock out starts")
    r = run("late: Mac sleeps through the window", from: (8, 15), late: true, sleeps: [600: 3600])
    check(r.punched == ["clock_in"] && has(r.events, "Clocked in at 09:25"), "late: slept past the window, clocks on wake")
    r = run("late: away all window, back later", from: (8, 15), ticks: 5000, late: true, idle: { $0 < 4000 ? 9999 : 0 })
    check(r.punched == ["clock_in"] && has(r.events, "Late clock in in 30s") && has(r.events, "Clocked in at 09:22"),
          "late: back after the window, 30s countdown, clocks in")
    r = run("demo during a real countdown", from: (8, 15), ticks: 20, script: [5: "demo"])
    check(has(r.events, "Demo not started"), "demo refused during a real countdown")
    r = run("demo", from: (12, 0), ticks: 60, tweak: { $0.types = ["clock_out"] }, script: [0: "demo"])
    check(r.punched.isEmpty && has(r.events, "Clock in in 30s") && has(r.events, "Demo: would clock in now"),
          "demo counts down and never punches")

    check((try? callbackResult("/callback?code=abc&state=s1", state: "s1")?.get()) == "abc", "callback: code")
    check(callbackResult("/callback?code=abc&state=other", state: "s1").map { (try? $0.get()) == nil } == true,
          "callback: another sign-in's answer refused")
    check(callbackResult("/callback?error=access_denied&state=s1", state: "s1").map { (try? $0.get()) == nil } == true,
          "callback: denied")
    check(callbackResult("/favicon.ico", state: "s1") == nil, "callback: other paths ignored")

    // secrets in a fake Keychain, files in a scratch config dir
    let tmpBase = ProcessInfo.processInfo.environment["TMPDIR"].map { URL(fileURLWithPath: $0) } ?? FileManager.default.temporaryDirectory
    let tmp = tmpBase.appendingPathComponent("freee-selftest-\(getpid())")
    try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }
    configDir = tmp
    envURL = tmp.appendingPathComponent("selftest-env.txt")
    let mem = MemoryStore()
    secrets = mem
    check((try? appCreds()) == nil && signedIn() == nil, "not signed in at first")
    try? "export ClientID='dummy-id'\nClientSecret=\"dummy-secret\"\n# comment\n".write(to: envURL, atomically: false, encoding: .utf8)
    try? JSONSerialization.data(withJSONObject: ["access_token": "dummy-a1", "refresh_token": "dummy-r1", "expires_at": 0])
        .write(to: oldTokenURL)
    importOldSecrets()
    let creds = try? appCreds()
    check(creds?.id == "dummy-id" && creds?.secret == "dummy-secret", ".env imported into the Keychain (export, quotes, comments)")
    check(mem.items["token"]?["refresh_token"] as? String == "dummy-r1" && !FileManager.default.fileExists(atPath: oldTokenURL.path),
          "token.json moved into the Keychain")
    var sent: [String: String] = [:]
    tokenPost = { form in
        sent = form
        return ["access_token": "dummy-a2", "refresh_token": "dummy-r2", "expires_in": 21600]
    }
    check((try? accessToken()) == "dummy-a2" && sent["refresh_token"] == "dummy-r1" && sent["redirect_uri"] == oobRedirect,
          "expired: refreshed with the old refresh token and its redirect")
    check(mem.items["token"]?["refresh_token"] as? String == "dummy-r2", "rotated refresh token saved")
    sent = [:]
    check((try? accessToken()) == "dummy-a2" && sent.isEmpty, "valid access token reused")
    try? saveConf(["id": 1, "employee_id": 2, "name": "dummy co"])
    check(signedIn()?.employee == 2, "signed in")
    signOut()
    check(signedIn() == nil && mem.items["token"] == nil && mem.items["app"] != nil,
          "sign out drops the sign-in, keeps the app credentials")

    print(bad == 0 ? "selftest: all passed" : "selftest: \(bad) failed")
    return bad == 0
}

// MARK: - Main

setvbuf(stdout, nil, _IOLBF, 0)  // line by line into the launchd log
let args = Array(CommandLine.arguments.dropFirst())
if args.first != "selftest" {
    settings = loadSettings()
    importOldSecrets()
}
do {
    switch args.first {
    case "setup", "auth":
        post("setup")
        print("opened Setup in the menu bar app (it must be running: install.sh)")
    case "status": try cliStatus()
    case "in", "out": try cliPunch(Kind(rawValue: args[0])!)
    case "demo":
        post("demo", args.count > 1 && args[1] == "out" ? "out" : "in")
        print("demo: 40s countdown in the menu bar (needs the menu bar app running)")
    case "bar":
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)  // menu bar only, no Dock icon
        app.mainMenu = editMenu()
        let bar = Bar()
        withExtendedLifetime(bar) { app.run() }
    case "selftest": exit(selftest() ? 0 : 1)
    default:
        print(usage)
        exit(2)
    }
} catch {
    fputs("\(error)\n", stderr)
    exit(1)
}
