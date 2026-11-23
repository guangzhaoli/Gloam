// Gloam — 极简的自动深浅色工具。事件驱动（不轮询）；常驻进程尽量不碰 AppKit，设置窗口是独立的短命进程。
import Carbon.HIToolbox
import Cocoa

let D = UserDefaults.standard

/// 界面语言：默认英文，可在设置里切换为中文。所有界面文字都写成 L("English", "中文")。
var zh: Bool { D.string(forKey: "lang") == "zh" }
func L(_ en: String, _ cn: String) -> String { zh ? cn : en }

/// 日程使用的日历：默认系统时区，可在设置里指定别的时区（系统时区本身不动）。
var cal: Calendar {
    var c = Calendar.current
    if let z = D.string(forKey: "tz").flatMap(TimeZone.init(identifier:)) { c.timeZone = z }
    return c
}

// MARK: 系统接口

let sky = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)

var isDark: Bool {
    if let s = dlsym(sky, "SLSGetAppearanceThemeLegacy") {
        return unsafeBitCast(s, to: (@convention(c) () -> Bool).self)()
    }
    return D.string(forKey: "AppleInterfaceStyle") == "Dark"
}

func setDark(_ on: Bool) {
    if let s = dlsym(sky, "SLSSetAppearanceThemeLegacy") {
        unsafeBitCast(s, to: (@convention(c) (Bool) -> Void).self)(on)
    } else {
        NSAppleScript(source: "tell application \"System Events\" to tell appearance preferences to set dark mode to \(on)")?
            .executeAndReturnError(nil)
    }
}

/// 暖色生效期间接管 Night Shift（关掉它），结束后原样交还。
let blueLight: NSObject? = {
    dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_LAZY)
    return (NSClassFromString("CBBlueLightClient") as? NSObject.Type)?.init()
}()

func nightShift(takeOver: Bool) {
    let saved = D.array(forKey: "ns") as? [Int]
    guard takeOver != (saved != nil), let c = blueLight else { return }
    let get = NSSelectorFromString("getBlueLightStatus:")
    let setM = NSSelectorFromString("setMode:"), setE = NSSelectorFromString("setEnabled:")
    guard c.responds(to: get), c.responds(to: setM), c.responds(to: setE) else { return }
    func mode(_ v: Int32) {
        _ = unsafeBitCast(c.method(for: setM), to: (@convention(c) (NSObject, Selector, Int32) -> Bool).self)(c, setM, v)
    }
    func enabled(_ v: Bool) {
        _ = unsafeBitCast(c.method(for: setE), to: (@convention(c) (NSObject, Selector, Bool) -> Bool).self)(c, setE, v)
    }
    if takeOver {
        // Status 结构体：{ BOOL active; BOOL enabled; BOOL sunSchedulePermitted; int mode; ... }
        var buf = [UInt8](repeating: 0, count: 256)
        let ok = buf.withUnsafeMutableBytes {
            unsafeBitCast(c.method(for: get), to: (@convention(c) (NSObject, Selector, UnsafeMutableRawPointer) -> Bool).self)(c, get, $0.baseAddress!)
        }
        guard ok else { return }
        let m = buf.withUnsafeBytes { $0.load(fromByteOffset: 4, as: Int32.self) }
        D.set([Int(m), Int(buf[1])], forKey: "ns")
        mode(0); enabled(false)
    } else if let s = saved, s.count == 2 {
        mode(Int32(s[0]))
        if s[0] == 0, s[1] == 1 { enabled(true) }
        D.removeObject(forKey: "ns")
    }
}

// MARK: 色温（gamma 表）

var gammaBase: [CGDirectDisplayID: [[CGGammaValue]]] = [:]
var currentK = 6500.0

func rgb(_ k: Double) -> [Double] {
    func raw(_ k: Double) -> [Double] {
        let t = k / 100
        let r = t <= 66 ? 255 : 329.698727446 * pow(t - 60, -0.1332047592)
        let g = t <= 66 ? 99.4708025861 * log(t) - 161.1195681661 : 288.1221695283 * pow(t - 60, -0.0755148492)
        let b = t >= 66 ? 255 : t <= 19 ? 0 : 138.5177312231 * log(t - 10) - 305.0447927307
        return [r, g, b].map { min(255, max(0, $0)) }
    }
    let w = raw(6500)
    return zip(raw(k), w).map { min(1, $0 / $1) }
}

func applyKelvin(_ k: Double, force: Bool = false) {
    guard force || abs(k - currentK) >= 1 else { return }
    currentK = k
    if k >= 6500 {
        if !gammaBase.isEmpty { CGDisplayRestoreColorSyncSettings(); gammaBase = [:] }
        return
    }
    let m = rgb(k)
    var ids = [CGDirectDisplayID](repeating: 0, count: 16), n: UInt32 = 0
    CGGetOnlineDisplayList(16, &ids, &n)
    for id in ids[..<Int(n)] {
        if gammaBase[id] == nil {
            let cap = CGDisplayGammaTableCapacity(id)
            var r = [CGGammaValue](repeating: 0, count: Int(cap)), g = r, b = r, c: UInt32 = 0
            guard CGGetDisplayTransferByTable(id, cap, &r, &g, &b, &c) == .success, c > 0 else { continue }
            gammaBase[id] = [r, g, b].map { Array($0[..<Int(c)]) }
        }
        let t = gammaBase[id]!.enumerated().map { i, ch in ch.map { $0 * CGGammaValue(m[i]) } }
        CGSetDisplayTransferByTable(id, UInt32(t[0].count), t[0], t[1], t[2])
    }
}

// MARK: 日程计算

func coord() -> (lat: Double, lon: Double)? {
    guard let a = D.object(forKey: "lat"), let b = D.object(forKey: "lon"),
          let la = Double("\(a)"), let lo = Double("\(b)"), abs(la) <= 90, abs(lo) <= 180 else { return nil }
    return (la, lo)
}

/// 设置里的"时:分"统一按 GMT 存取（时间选择器也用 GMT），这样系统换时区后钟点不会跟着变。
let gmt: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "GMT")!
    return c
}()

func hour(_ h: Int) -> Date { gmt.date(bySettingHour: h, minute: 0, second: 0, of: Date(timeIntervalSinceReferenceDate: 0))! }

func at(_ day: Date, _ key: String) -> Date {
    let c = gmt.dateComponents([.hour, .minute], from: D.object(forKey: key) as? Date ?? Date(timeIntervalSinceReferenceDate: 0))
    return cal.date(bySettingHour: c.hour ?? 0, minute: c.minute ?? 0, second: 0, of: day) ?? day
}

/// 指定本地日（零点）的日出日落；没有位置时退回自定义时间。
func sun(_ day: Date) -> (rise: Date, set: Date) {
    guard let (lat, lon) = coord() else { return (at(day, "lightTime"), at(day, "darkTime")) }
    let rad = Double.pi / 180
    let n = ((day.timeIntervalSince1970 + 43200) / 86400 + 2440587.5 - 2451545 + lon / 360).rounded()
    let j = n - lon / 360 + 0.0008
    let M = (357.5291 + 0.98560028 * j).truncatingRemainder(dividingBy: 360) * rad
    let L = (M / rad + 1.9148 * sin(M) + 0.02 * sin(2 * M) + 0.0003 * sin(3 * M) + 282.9372) * rad
    let transit = 2451545 + j + 0.0053 * sin(M) - 0.0069 * sin(2 * L)
    let dec = asin(sin(L) * sin(23.4397 * rad))
    let c = (sin(-0.833 * rad) - sin(lat * rad) * sin(dec)) / (cos(lat * rad) * cos(dec))
    if c > 1 { return (day + 43200, day + 43200) }  // 极夜：同一时刻先浅后深 → 全天深色
    if c < -1 { return (day, day - 1) }             // 极昼：深色事件排在浅色之前 → 全天浅色
    let w = acos(c) / rad / 360
    func date(_ jd: Double) -> Date { Date(timeIntervalSince1970: ((jd - 2440587.5) * 86400).rounded()) }
    return (date(transit - w), date(transit + w))
}

/// 某一天的两个切换点。日出日落模式下还没有位置时返回 nil（不自动切换）。
func schedule(_ day: Date) -> (light: Date, dark: Date)? {
    if D.integer(forKey: "mode") == 0 {
        guard coord() != nil else { return nil }
        let s = sun(day)
        return (s.rise + D.double(forKey: "riseOff") * 60, s.set + D.double(forKey: "setOff") * 60)
    }
    return (at(day, "lightTime"), at(day, "darkTime"))
}

func forecastKey(_ now: Date) -> String? {
    guard let (la, lo) = coord() else { return nil }
    return String(format: "%.0f,%.2f,%.2f", cal.startOfDay(for: now).timeIntervalSince1970, la, lo)
}

/// 天气：从某个整点起云量一直够"暗"到日落，就把当天的深色提前到那个整点（一天只切一次，不来回跳）。
func weatherDark(_ now: Date, _ light: Date, _ dark: Date) -> Date? {
    guard D.bool(forKey: "weather"), D.string(forKey: "fcKey") == forecastKey(now),
          let fc = D.dictionary(forKey: "fc") as? [String: [Double]],
          let ts = fc["time"], let cloud = fc["cloud_cover"], let code = fc["weather_code"],
          cloud.count == ts.count, code.count == ts.count else { return nil }
    let thr = [70.0, 85, 95][min(2, max(0, D.integer(forKey: "level")))]
    var start: Date?
    for (i, t) in ts.enumerated() {
        let d = Date(timeIntervalSince1970: t)
        guard d + 3600 > light, d < dark else { continue }
        if cloud[i] >= thr || code[i] >= 95 { start = start ?? max(d, light) } else { start = nil }
    }
    return start
}

/// 昨天、今天、明天的全部切换点，按时间排序。
func events(_ now: Date) -> [(t: Date, dark: Bool)] {
    var out: [(t: Date, dark: Bool)] = []
    let today = cal.startOfDay(for: now)
    for i in -1...1 {
        guard let (l, d) = schedule(cal.date(byAdding: .day, value: i, to: today)!) else { continue }
        out.append((l, false))
        out.append(((i == 0 ? weatherDark(now, l, d) : nil) ?? d, true))
    }
    return out.sorted { $0.t < $1.t || ($0.t == $1.t && !$0.dark && $1.dark) }
}

/// 当前应有的色温，以及下次需要重新计算的时间。起止各有 30 分钟渐变。
func warmth(_ now: Date) -> (k: Double, next: Date) {
    guard D.bool(forKey: "warm") else { return (6500, .distantFuture) }
    let target = min(6500, max(1900, D.double(forKey: "kelvin"))), mode = D.integer(forKey: "warmMode")
    if mode == 2 { return (target, .distantFuture) }
    let ramp = 1800.0, today = cal.startOfDay(for: now)
    for i in -1...1 {
        let day = cal.date(byAdding: .day, value: i, to: today)!
        let s = mode == 1 ? at(day, "warmTime") : sun(day).set
        let e = [sun(day).rise, sun(cal.date(byAdding: .day, value: 1, to: day)!).rise].first { $0 > s } ?? s
        if now < s { return (6500, s) }
        if now < e {
            let p = min(1, now.timeIntervalSince(s) / ramp, e.timeIntervalSince(now) / ramp)
            let ramping = p < 1 || e.timeIntervalSince(now) <= ramp
            return (6500 + (target - 6500) * p, ramping ? now + 20 : e - ramp)
        }
    }
    return (6500, now + 3600)
}

/// 当前小时的天气读数（常驻进程抓取后存在设置里，两个进程都从这里读）。
func weatherLine(_ now: Date) -> String? {
    guard D.bool(forKey: "weather"), D.string(forKey: "fcKey") == forecastKey(now),
          let fc = D.dictionary(forKey: "fc") as? [String: [Double]], let ts = fc["time"],
          let i = ts.lastIndex(where: { $0 <= now.timeIntervalSince1970 }) else { return nil }
    func v(_ k: String) -> Double { fc[k].flatMap { $0.indices.contains(i) ? $0[i] : nil } ?? 0 }
    let f = D.integer(forKey: "fahrenheit") == 1, c = v("temperature_2m")
    return String(format: L("Cloud %.0f%% · Rain %.0f%% · UV %.0f · %.0f%@", "云 %.0f%% · 雨 %.0f%% · UV %.0f · %.0f%@"),
                  v("cloud_cover"), v("precipitation_probability"), v("uv_index"), (f ? c * 9 / 5 + 32 : c).rounded() + 0, f ? "°F" : "°C")
}

/// 状态说明："19:00 转为深色"，或者为什么现在不会自动切换。
func nextSwitch(_ now: Date) -> String {
    let dark = isDark, mode = D.integer(forKey: "mode")
    if mode == 2 { return L("Manual mode, no automatic switching", "手动模式，不会自动切换") }
    if mode == 0, coord() == nil { return L("No location yet, not switching", "还没有位置，暂不自动切换") }
    guard let n = events(now).first(where: { $0.t > now && $0.dark != dark }) else { return "" }
    let f = DateFormatter()
    f.timeStyle = .short
    f.timeZone = cal.timeZone
    let time = f.string(from: n.t)
    var s = zh ? "\(time) 转为\(n.dark ? "深色" : "浅色")" : "\(n.dark ? "Dark" : "Light") at \(time)"
    if cal.timeZone != TimeZone.current, let z = cal.timeZone.localizedName(for: .generic, locale: Locale(identifier: zh ? "zh_CN" : "en_US")) {
        s += " · " + z
    }
    return s
}

// MARK: 进程间约定
//
// 为了把常驻内存压到最低，Gloam 分成两种进程（同一个可执行文件）：
//   · 常驻进程：算日程、切外观、调色温、响应快捷键。不显示菜单栏图标时完全不启动 AppKit。
//   · 设置进程：`Gloam --settings`，只在设置窗口打开期间存在，关窗即退出，内存全部归还。
// 两者共用同一份设置，靠下面几个分布式通知互相知会。

enum Note {
    static let changed = "local.gloam.changed"  // 设置进程 → 常驻进程：设置改了
    static let state = "local.gloam.state"      // 常驻进程 → 设置进程：天气等状态更新了
    static let preview = "local.gloam.preview"  // 设置进程 → 常驻进程：预览色温（object 是开尔文数）
    static let show = "local.gloam.show"        // 再次启动 → 已开着的设置进程：把窗口带到前面
    static let quit = "local.gloam.quit"        // 任一方 → 所有进程：退出

    static func post(_ name: String, _ object: String? = nil) {
        DistributedNotificationCenter.default().postNotificationName(.init(name), object: object, userInfo: nil, deliverImmediately: true)
    }

    static func observe(_ name: String, _ target: Any, _ sel: Selector) {
        DistributedNotificationCenter.default().addObserver(target, selector: sel, name: .init(name), object: nil,
                                                            suspensionBehavior: .deliverImmediately)
    }
}

/// 单实例锁：拿得到说明同名角色还没有在运行。文件描述符故意不关（进程退出或 exec 时自动释放）。
func acquire(_ name: String) -> Bool {
    let fm = FileManager.default
    guard let dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.appendingPathComponent("Gloam") else { return true }
    try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
    let fd = open(dir.appendingPathComponent(name).path, O_CREAT | O_RDWR | O_CLOEXEC, 0o644)
    guard fd >= 0 else { return true }
    if flock(fd, LOCK_EX | LOCK_NB) == 0 { return true }
    close(fd)
    return false
}

/// 最轻形态：不显示图标、也没有全局快捷键，用最普通的事件循环，约 4 MB。
var lightest: Bool { !D.bool(forKey: "showIcon") && D.integer(forKey: "hkMods") == 0 }

/// 另起一个脱离当前进程的常驻进程。它不是经由系统"启动应用"产生的，系统不会把它当成正在运行的 Gloam，
/// 于是用户再次双击 Gloam 时会正常启动一个新实例（那个实例发现常驻进程已在，就去打开设置）。
func spawnDetachedAgent() {
    guard let path = Bundle.main.executablePath else { return }
    var attr: posix_spawnattr_t?
    posix_spawnattr_init(&attr)
    posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID))
    var argv: [UnsafeMutablePointer<CChar>?] = [strdup(path), strdup("--agent"), nil]
    var env: [UnsafeMutablePointer<CChar>?] = ProcessInfo.processInfo.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
    var pid: pid_t = 0
    posix_spawn(&pid, path, nil, &attr, &argv, &env)
    posix_spawnattr_destroy(&attr)
}

// MARK: 常驻进程

final class Agent: NSObject, NSApplicationDelegate, NSMenuDelegate {
    /// 启动时就定下的两个形态开关；之后设置变了就原地重启自己来切换。
    let iconMode = D.bool(forKey: "showIcon"), hotMode = D.integer(forKey: "hkMods") != 0
    var item: NSStatusItem?
    var timer: Timer?, hotKey: EventHotKeyRef?
    var fetching = false, retryAt = Date.distantPast, previewUntil = Date.distantPast, lastToggle = Date.distantPast
    var menuUsed = false, menuOpen = false

    // 只有显示菜单栏图标时才会走到这里（那时才有 NSApplication）。
    func applicationDidFinishLaunching(_: Notification) {
        let i = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        i.menu = menu
        item = i
        start()
    }

    func applicationShouldHandleReopen(_: NSApplication, hasVisibleWindows _: Bool) -> Bool {
        openSettings(); return false
    }

    @objc func reopen(_: NSAppleEventDescriptor, reply _: NSAppleEventDescriptor) { openSettings() }

    /// 两种形态共用的初始化：全部基于通知和定时器，不依赖 NSApplication。
    func start() {
        let ws = NSWorkspace.shared.notificationCenter, nc = NotificationCenter.default
        ws.addObserver(self, selector: #selector(displaysChanged), name: NSWorkspace.didWakeNotification, object: nil)
        ws.addObserver(self, selector: #selector(displaysChanged), name: NSWorkspace.screensDidWakeNotification, object: nil)
        ws.addObserver(self, selector: #selector(themeChanged), name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        nc.addObserver(self, selector: #selector(settingsSettled), name: .NSSystemClockDidChange, object: nil)
        nc.addObserver(self, selector: #selector(settingsSettled), name: .NSSystemTimeZoneDidChange, object: nil)
        nc.addObserver(self, selector: #selector(defaultsChanged), name: UserDefaults.didChangeNotification, object: nil)
        Note.observe("AppleInterfaceThemeChangedNotification", self, #selector(themeChanged))
        Note.observe(Note.changed, self, #selector(defaultsChanged))
        Note.observe(Note.preview, self, #selector(preview(_:)))
        Note.observe(Note.quit, self, #selector(quit))
        CGDisplayRegisterReconfigurationCallback({ _, flags, _ in
            guard !flags.contains(.beginConfigurationFlag), let a = agent else { return }
            NSObject.cancelPreviousPerformRequests(withTarget: a, selector: #selector(Agent.displaysChanged), object: nil)
            a.perform(#selector(Agent.displaysChanged), with: nil, afterDelay: 1)
        }, nil)
        if iconMode || hotMode {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetEventDispatcherTarget(), { _, _, _ in agent?.toggle(); return noErr }, 1, &spec, nil, nil)
            registerHotKey()
        }
        themeChanged()
        evaluate()
        // 还没有位置时不主动申请定位权限，而是打开设置让用户选城市或点"定位"。
        if D.integer(forKey: "mode") == 0, coord() == nil { openSettings() }
    }

    // 核心：算出"现在该是什么状态"，应用一次，然后只挂一个定时器到下一个切换点。
    @objc func evaluate() {
        timer?.invalidate()
        let now = Date()
        var next = now + 86400
        if D.bool(forKey: "weather"), let key = forecastKey(now), D.string(forKey: "fcKey") != key {
            if now >= retryAt { fetch(key) } else { next = min(next, retryAt) }
        }
        let evs = D.integer(forKey: "mode") == 2 ? [] : events(now)
        // 只在跨过新的切换点时才动外观，手动切换因此能保持到下一个切换点。
        if let last = evs.last(where: { $0.t <= now }), last.t.timeIntervalSince1970 != D.double(forKey: "lastT") {
            D.set(last.t.timeIntervalSince1970, forKey: "lastT")
            if isDark != last.dark { setDark(last.dark) }
        } else if evs.isEmpty, D.object(forKey: "lastT") != nil {
            D.removeObject(forKey: "lastT")  // 自动切换停用期间不留记录，重新启用时会立即按日程应用一次
        }
        if let n = evs.first(where: { $0.t > now }) { next = min(next, n.t) }
        let w = warmth(now)
        nightShift(takeOver: w.k < 6500)
        if now >= previewUntil { applyKelvin(w.k) } else { next = min(next, previewUntil) }
        next = min(next, w.next)
        let t = Timer(fire: next + 0.5, interval: 0, repeats: false) { [weak self] _ in self?.evaluate() }
        t.tolerance = min(5, max(0.1, next.timeIntervalSince(now) / 20))  // 离得近的（如 3 秒预览）要准时
        RunLoop.main.add(t, forMode: .common)
        timer = t
        if menuUsed, !menuOpen {
            NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(shed), object: nil)
            perform(#selector(shed), with: nil, afterDelay: 30)
        }
    }

    @objc func defaultsChanged() {
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(settingsSettled), object: nil)
        perform(#selector(settingsSettled), with: nil, afterDelay: 0.15)
    }

    @objc func settingsSettled() {
        CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication)  // 设置是另一个进程写的，先确保读到最新值
        if D.bool(forKey: "showIcon") != iconMode || (!iconMode && (D.integer(forKey: "hkMods") != 0) != hotMode) { reexec() }
        if iconMode || hotMode { registerHotKey() }
        evaluate()
        syncWallpaper()
    }

    @objc func displaysChanged() {
        // 唤醒或显示器变化后系统可能已重置 gamma：先还原再重新叠加，避免重复叠加。
        if currentK < 6500 { CGDisplayRestoreColorSyncSettings(); gammaBase = [:]; currentK = 6500 }
        evaluate(); syncWallpaper()
        // 屏幕点亮后系统有时会晚几秒才重置 gamma，届时再补一次，免得暖色丢到下个切换点。
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(reapplyWarmth), object: nil)
        perform(#selector(reapplyWarmth), with: nil, afterDelay: 5)
    }

    @objc func reapplyWarmth() {
        if currentK < 6500, Date() >= previewUntil { applyKelvin(currentK, force: true) }
    }

    /// 设置窗口拖动色温滑块时的实时预览，3 秒后回到日程应有的值。
    @objc func preview(_ n: Notification) {
        guard let k = (n.object as? String).flatMap(Double.init) else { return }
        previewUntil = Date() + 3
        applyKelvin(min(6500, max(1900, k)), force: true)
        evaluate()
    }

    @objc func themeChanged() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            if let b = self.item?.button {
                let img = symbol(isDark ? "moon.stars.fill" : "sun.max.fill", 14, .medium)
                img?.isTemplate = true
                b.image = img
            }
            self.syncWallpaper()
        }
    }

    @objc func toggle() {
        // 快捷键连按或重复触发时，0.4 秒内只认一次。
        let now = Date()
        guard now.timeIntervalSince(lastToggle) > 0.4 else { return }
        lastToggle = now
        setDark(!isDark)
    }

    func syncWallpaper() {
        guard D.bool(forKey: "wall"), let p = D.string(forKey: isDark ? "wallDark" : "wallLight"),
              FileManager.default.fileExists(atPath: p) else { return }
        let url = URL(fileURLWithPath: p), ws = NSWorkspace.shared
        for s in NSScreen.screens where ws.desktopImageURL(for: s) != url {
            try? ws.setDesktopImageURL(url, for: s, options: ws.desktopImageOptions(for: s) ?? [:])
        }
    }

    /// 重启自己：用来切换形态，或在用过菜单后把涨上去的内存甩掉。
    func reexec() {
        guard let path = Bundle.main.executablePath else { return }
        timer?.invalidate()
        // 最轻形态不处理系统事件，所以必须是一个系统"不认识"的新进程（见 spawnDetachedAgent）；
        // 其余情况原地 exec，进程号不变。
        if lightest { spawnDetachedAgent(); exit(0) }
        var argv: [UnsafeMutablePointer<CChar>?] = [strdup(path), nil]
        execv(path, &argv)  // 成功则不会返回；失败就留在原形态继续运行
    }

    /// 菜单弹出一次会让 AppKit 多占约 8 MB 且不归还；菜单关闭 30 秒后重启自己回到最低水平。
    /// 暖色生效期间不重启（重启会让屏幕色温闪一下），等它结束后再说。
    @objc func shed() {
        if menuUsed, !menuOpen, currentK >= 6500, Date() >= previewUntil { reexec() }
    }

    // MARK: 天气（Open-Meteo，无需密钥；每天每个位置只请求一次）

    /// 用系统自带的 curl 子进程去取，常驻进程自己不加载联网框架。
    func fetch(_ key: String) {
        guard !fetching, let (la, lo) = coord() else { return }
        fetching = true
        let fields = ["cloud_cover", "precipitation_probability", "uv_index", "temperature_2m", "weather_code"]
        let p = Process(), pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        p.arguments = ["-s", "--max-time", "20", "https://api.open-meteo.com/v1/forecast?latitude=\(String(format: "%.2f", la))&longitude=\(String(format: "%.2f", lo))&hourly=\(fields.joined(separator: ","))&forecast_days=2&timeformat=unixtime&timezone=auto"]
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        p.terminationHandler = { _ in
            let data = pipe.fileHandleForReading.readDataToEndOfFile()  // 响应只有几 KB，远小于管道缓冲
            let h = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["hourly"] as? [String: Any]
            var fc: [String: [Double]] = [:]
            for k in ["time"] + fields {
                fc[k] = (h?[k] as? [Any])?.map { ($0 as? NSNumber)?.doubleValue ?? 0 }
            }
            DispatchQueue.main.async {
                self.fetching = false
                if fc.count == fields.count + 1 {
                    D.set(fc, forKey: "fc"); D.set(key, forKey: "fcKey")
                    Note.post(Note.state)
                } else {
                    self.retryAt = Date() + 1800
                }
                self.evaluate()
            }
        }
        do { try p.run() } catch { fetching = false; retryAt = Date() + 1800 }
    }

    // MARK: 全局快捷键

    func registerHotKey() {
        if let h = hotKey { UnregisterEventHotKey(h); hotKey = nil }
        let mods = D.integer(forKey: "hkMods")
        guard mods != 0 else { return }
        RegisterEventHotKey(UInt32(D.integer(forKey: "hkCode")), UInt32(mods),
                            EventHotKeyID(signature: 0x474C_4F4D, id: 1), GetEventDispatcherTarget(), 0, &hotKey)
    }

    // MARK: 菜单（每次打开时现算，平时不刷新）

    func menuWillOpen(_: NSMenu) { menuOpen = true }

    func menuDidClose(_: NSMenu) {
        menuOpen = false
        menuUsed = true
        DispatchQueue.main.async { self.evaluate() }  // 等菜单项的动作执行完，再安排甩内存
    }

    func menuNeedsUpdate(_ m: NSMenu) {
        m.removeAllItems()
        let now = Date(), dark = isDark

        // 顶部状态：图标 + 当前外观 + 下一次切换 / 天气 / 色温
        var lines = [nextSwitch(now)]
        if let w = weatherLine(now) { lines.append(w) }
        if currentK < 6500 { lines.append(L("Warmth", "暖色") + " \(Int(currentK))K") }
        let icon = NSImageView(image: symbol(dark ? "moon.stars.fill" : "sun.max.fill", 20, .medium) ?? NSImage())
        icon.contentTintColor = dark ? .systemIndigo : .systemOrange
        icon.widthAnchor.constraint(equalToConstant: 28).isActive = true
        let title = NSTextField(labelWithString: dark ? L("Dark appearance", "深色外观") : L("Light appearance", "浅色外观"))
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        let text = NSStackView(views: [title] + lines.filter { !$0.isEmpty }.map {
            let l = NSTextField(labelWithString: $0)
            l.font = .systemFont(ofSize: 11); l.textColor = .secondaryLabelColor
            return l
        })
        text.orientation = .vertical; text.alignment = .leading; text.spacing = 2
        let head = NSStackView(views: [icon, text])
        head.spacing = 8
        head.edgeInsets = NSEdgeInsets(top: 6, left: 14, bottom: 8, right: 18)
        head.frame.size = head.fittingSize
        let headItem = NSMenuItem()
        headItem.view = head
        m.addItem(headItem)
        m.addItem(.separator())

        func add(_ title: String, _ icon: String, _ sel: Selector, _ key: String = "") -> NSMenuItem {
            let i = m.addItem(withTitle: title, action: sel, keyEquivalent: key)
            i.image = symbol(icon, 13)
            i.target = self
            return i
        }
        // 快捷键只写在标题里当提示：真正的响应由全局热键负责，这里不绑按键，免得同一次按键触发两回。
        let hint = D.integer(forKey: "hkMods") != 0 ? "　" + (D.string(forKey: "hkName") ?? "") : ""
        _ = add((dark ? L("Switch to Light", "切换为浅色") : L("Switch to Dark", "切换为深色")) + hint, dark ? "sun.max" : "moon", #selector(toggle))
        add(L("Evening Warmth", "暖色屏幕"), "sun.dust", #selector(toggleWarm)).state = D.bool(forKey: "warm") ? .on : .off
        m.addItem(.separator())
        _ = add(L("Settings…", "设置…"), "gearshape", #selector(openSettings), ",")
        _ = add(L("Quit Gloam", "退出 Gloam"), "power", #selector(quit), "q")
    }

    @objc func toggleWarm() { D.set(!D.bool(forKey: "warm"), forKey: "warm") }

    /// 设置窗口是一个独立的短命进程，关窗即退出。经由系统正常启动，它有自己完整的应用身份（定位授权等）。
    @objc func openSettings() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-n", Bundle.main.bundlePath, "--args", "--settings"]
        try? p.run()
    }

    @objc func quit() {
        applyKelvin(6500)
        nightShift(takeOver: false)
        CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication)
        Note.post(Note.quit)  // 让开着的设置窗口一起退出
        exit(0)
    }

    func run() -> Never {
        if iconMode {
            NSApplication.shared.delegate = self
            NSApp.setActivationPolicy(.accessory)
            NSApp.run()
        } else {
            // 不显示图标：完全不启动 NSApplication。
            start()
            NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(reopen(_:reply:)),
                                                         forEventClass: AEEventClass(kCoreEventClass), andEventID: AEEventID(kAEReopenApplication))
            // 全局快捷键要靠 Carbon 事件循环才收得到（约多占 2.5 MB）；没设快捷键就用最轻的普通事件循环。
            if hotMode, let f = dlsym(dlopen("/System/Library/Frameworks/Carbon.framework/Frameworks/HIToolbox.framework/HIToolbox", RTLD_LAZY), "RunApplicationEventLoop") {
                unsafeBitCast(f, to: (@convention(c) () -> Void).self)()
            }
            RunLoop.main.run()
        }
        exit(0)
    }
}

var agent: Agent?

// MARK: 入口

D.register(defaults: [
    "lang": "en", "mode": 0, "riseOff": 0, "setOff": 0, "lightTime": hour(7), "darkTime": hour(19),
    "weather": false, "level": 1, "fahrenheit": 0,
    "warm": false, "kelvin": 3400, "warmMode": 0, "warmTime": hour(20),
    "wall": false, "showIcon": true, "hkCode": kVK_ANSI_D, "hkMods": cmdKey | optionKey | controlKey, "hkName": "⌃⌥⌘D",
])

let arguments = CommandLine.arguments

// `Gloam --status`：打印日程后退出，便于排查。
if arguments.contains("--status") {
    let now = Date(), f = DateFormatter()
    f.dateFormat = "MM-dd HH:mm"
    f.timeZone = cal.timeZone
    print(L("Schedule time zone:", "日程时区:"), cal.timeZone.identifier)
    print(L("Location:", "位置:"), coord().map { "\($0.lat), \($0.lon)" }
        ?? (D.integer(forKey: "mode") == 0 ? L("not set (no automatic switching in sunrise/sunset mode)", "未设置（日出日落模式下不会自动切换）") : L("not set", "未设置")))
    for e in events(now) { print(f.string(from: e.t), e.dark ? L("dark", "深色") : L("light", "浅色"), e.t <= now ? "" : L("(upcoming)", "（未到）")) }
    print(L("Appearance:", "当前外观:"), isDark ? L("dark", "深色") : L("light", "浅色"), L("· colour temperature:", "· 色温:"), Int(warmth(now).k), "K")
    exit(0)
}

// `Gloam --permissions`：只读地打印各项权限状态，不申请、不修改任何东西。
if arguments.contains("--permissions") { printPermissions(); exit(0) }

if arguments.contains("--settings") { runSettings() }

if arguments.contains("--agent") {
    // 由上一个常驻进程交接而来：等它退出、让出锁（最多 5 秒）。
    var tries = 0
    while !acquire("agent.lock") {
        tries += 1
        if tries > 50 { exit(0) }
        usleep(100_000)
    }
} else if !acquire("agent.lock") {
    runSettings()  // 常驻进程已经在跑，说明这次是用户再次打开应用 → 这个进程只负责设置窗口
} else if lightest {
    spawnDetachedAgent()  // 最轻形态：把常驻的活交给一个脱离出去的进程，自己退出（退出时自动让出锁）
    exit(0)
}

let a = Agent()
agent = a
a.run()
