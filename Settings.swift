// 设置进程：分页 + 卡片式的设置窗口。它是独立的短命进程（`Gloam --settings`），关窗即退出，内存全部归还。
import Carbon.HIToolbox
import Cocoa
import CoreLocation
import ServiceManagement

// MARK: 小工具

private func bindD(_ v: NSObject, _ b: NSBindingName, _ key: String) {
    v.bind(b, to: NSUserDefaultsController.shared, withKeyPath: "values." + key, options: nil)
}

private final class Handler: NSObject {
    let f: () -> Void
    init(_ f: @escaping () -> Void) { self.f = f }
    @objc func run() { f() }
}

private var handlerKey: UInt8 = 0

/// 给控件挂一个闭包动作。
@discardableResult
private func on<T: NSControl>(_ c: T, _ f: @escaping (T) -> Void) -> T {
    let h = Handler { [unowned c] in f(c) }
    c.target = h
    c.action = #selector(Handler.run)
    objc_setAssociatedObject(c, &handlerKey, h, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    return c
}

private func label(_ s: String = "", _ size: CGFloat = 13, _ weight: NSFont.Weight = .regular,
                   _ color: NSColor = .labelColor) -> NSTextField {
    let l = NSTextField(labelWithString: s)
    l.font = .systemFont(ofSize: size, weight: weight)
    l.textColor = color
    return l
}

private func note(_ s: String = "") -> NSTextField { label(s, 11, .regular, .secondaryLabelColor) }

private func stack(_ o: NSUserInterfaceLayoutOrientation, _ v: [NSView], _ spacing: CGFloat = 8) -> NSStackView {
    let s = NSStackView(views: v)
    s.orientation = o
    s.spacing = spacing
    s.alignment = o == .vertical ? .leading : .centerY
    s.setHuggingPriority(.defaultHigh, for: .horizontal)  // 贴合内容，才能在行里靠右
    return s
}

func symbol(_ name: String, _ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSImage? {
    NSImage(systemSymbolName: name, accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: size, weight: weight))
}

private func segmented(_ labels: [String], _ key: String) -> NSSegmentedControl {
    let s = NSSegmentedControl(labels: labels, trackingMode: .selectOne, target: nil, action: nil)
    bindD(s, .selectedIndex, key)
    return s
}

private func timePicker(_ key: String) -> NSDatePicker {
    let p = NSDatePicker()
    p.datePickerStyle = .textFieldAndStepper
    p.datePickerElements = .hourMinute
    p.calendar = gmt  // "时:分"按 GMT 存取，见 main.swift 的 at()
    p.timeZone = gmt.timeZone
    bindD(p, .value, key)
    return p
}

private func isDarkAppearance(_ v: NSView) -> Bool {
    v.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
}

/// 一行设置：左边标题（可带一行说明），右边控件。
private func row(_ title: String, _ sub: NSView? = nil, _ control: NSView? = nil) -> NSStackView {
    let left = stack(.vertical, [label(title)] + (sub.map { [$0] } ?? []), 2)
    let r = NSStackView()
    r.orientation = .horizontal
    r.alignment = .centerY
    r.addView(left, in: .leading)
    if let c = control { r.addView(c, in: .trailing) }
    r.edgeInsets = NSEdgeInsets(top: 9, left: 14, bottom: 9, right: 14)
    r.heightAnchor.constraint(greaterThanOrEqualToConstant: 46).isActive = true
    return r
}

/// 圆角卡片，行与行之间有细分隔线。颜色随深浅色自动更新。
private final class Card: NSView {
    init(_ rows: [NSView]) {
        super.init(frame: .zero)
        wantsLayer = true
        let s = stack(.vertical, [], 0)
        for (i, r) in rows.enumerated() {
            if i > 0 {
                let line = NSBox(); line.boxType = .separator
                let holder = NSView()
                holder.addSubview(line)
                line.translatesAutoresizingMaskIntoConstraints = false
                NSLayoutConstraint.activate([
                    holder.heightAnchor.constraint(equalToConstant: 1),
                    line.leadingAnchor.constraint(equalTo: holder.leadingAnchor, constant: 14),
                    line.trailingAnchor.constraint(equalTo: holder.trailingAnchor),
                    line.centerYAnchor.constraint(equalTo: holder.centerYAnchor),
                ])
                s.addArrangedSubview(holder)
                holder.widthAnchor.constraint(equalTo: s.widthAnchor).isActive = true
            }
            s.addArrangedSubview(r)
            r.widthAnchor.constraint(equalTo: s.widthAnchor).isActive = true
        }
        addSubview(s)
        s.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            s.topAnchor.constraint(equalTo: topAnchor), s.bottomAnchor.constraint(equalTo: bottomAnchor),
            s.leadingAnchor.constraint(equalTo: leadingAnchor), s.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    required init?(coder _: NSCoder) { nil }
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        let dark = isDarkAppearance(self)
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        layer?.backgroundColor = NSColor(white: dark ? 1 : 0, alpha: dark ? 0.055 : 0.03).cgColor
        layer?.borderColor = NSColor(white: dark ? 1 : 0, alpha: dark ? 0.09 : 0.08).cgColor
    }
}

/// 标题 + 卡片 + 脚注。
private func section(_ title: String?, _ rows: [NSView], footer: String? = nil) -> NSStackView {
    let s = stack(.vertical, [], 7)
    if let t = title { s.addArrangedSubview(label("  " + t, 12, .semibold, .secondaryLabelColor)) }
    let c = Card(rows)
    s.addArrangedSubview(c)
    c.widthAnchor.constraint(equalTo: s.widthAnchor).isActive = true
    if let f = footer {
        let l = NSTextField(wrappingLabelWithString: f)
        l.font = .systemFont(ofSize: 11)
        l.textColor = .secondaryLabelColor
        l.isSelectable = false
        s.addArrangedSubview(l)
        l.widthAnchor.constraint(equalTo: s.widthAnchor, constant: -12).isActive = true
        s.setCustomSpacing(8, after: c)
    }
    return s
}

private func pane(_ title: String, _ icon: String, _ sections: [NSView]) -> NSTabViewItem {
    let s = stack(.vertical, [], 18)
    for v in sections {
        s.addArrangedSubview(v)
        v.widthAnchor.constraint(equalTo: s.widthAnchor).isActive = true
    }
    let root = NSView()
    root.addSubview(s)
    s.translatesAutoresizingMaskIntoConstraints = false
    let bottom = root.bottomAnchor.constraint(greaterThanOrEqualTo: s.bottomAnchor, constant: 24)
    let trailing = root.trailingAnchor.constraint(equalTo: s.trailingAnchor, constant: 24)
    bottom.priority = .init(999); trailing.priority = .init(999)
    NSLayoutConstraint.activate([
        s.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
        s.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
        s.widthAnchor.constraint(equalToConstant: 440), bottom, trailing,
    ])
    let vc = NSViewController()
    vc.view = root
    let item = NSTabViewItem(viewController: vc)
    item.label = title
    item.image = symbol(icon, 16)
    return item
}

/// 工具栏分页；切换分页或内容变化时让窗口贴合内容高度。
private final class Tabs: NSTabViewController {
    override func tabView(_ t: NSTabView, didSelect item: NSTabViewItem?) {
        super.tabView(t, didSelect: item)
        view.window?.title = item?.label ?? "Gloam"
        fit(animate: true)
    }

    func fit(animate: Bool) {
        guard let w = view.window, tabViewItems.indices.contains(selectedTabViewItemIndex),
              let v = tabViewItems[selectedTabViewItemIndex].view else { return }
        v.layoutSubtreeIfNeeded()
        var f = w.frameRect(forContentRect: NSRect(origin: .zero, size: v.fittingSize))
        f.origin = NSPoint(x: w.frame.minX, y: w.frame.maxY - f.height)
        if f != w.frame { w.setFrame(f, display: true, animate: animate) }
    }
}

/// 色温滑块：轨道画成暖色到冷白的渐变。
private final class WarmCell: NSSliderCell {
    override func drawBar(inside r: NSRect, flipped _: Bool) {
        let bar = NSRect(x: r.minX, y: r.midY - 3, width: r.width, height: 6)
        NSGradient(colors: [NSColor(srgbRed: 1, green: 0.55, blue: 0.2, alpha: 1),
                            NSColor(srgbRed: 1, green: 0.85, blue: 0.62, alpha: 1),
                            NSColor(srgbRed: 0.86, green: 0.92, blue: 1, alpha: 1)])?
            .draw(in: NSBezierPath(roundedRect: bar, xRadius: 3, yRadius: 3), angle: 0)
    }
}

/// 壁纸缩略图：点击选择图片。用系统缩略图解码，不把整张原图读进内存。
private final class Thumb: NSView {
    let key: String
    private let placeholder = NSImageView()
    private var loaded: String?

    init(_ key: String) {
        self.key = key
        super.init(frame: .zero)
        wantsLayer = true
        layer?.contentsGravity = .resizeAspectFill
        layer?.masksToBounds = true
        placeholder.image = symbol("photo.badge.plus", 26, .light)
        placeholder.contentTintColor = .tertiaryLabelColor
        let button = on(NSButton(title: "", target: nil, action: nil)) { [unowned self] _ in self.choose() }
        button.isTransparent = true
        for v in [placeholder, button] as [NSView] {
            addSubview(v)
            v.translatesAutoresizingMaskIntoConstraints = false
        }
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 200), heightAnchor.constraint(equalToConstant: 125),
            placeholder.centerXAnchor.constraint(equalTo: centerXAnchor), placeholder.centerYAnchor.constraint(equalTo: centerYAnchor),
            button.topAnchor.constraint(equalTo: topAnchor), button.bottomAnchor.constraint(equalTo: bottomAnchor),
            button.leadingAnchor.constraint(equalTo: leadingAnchor), button.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        toolTip = "点击选择图片"
        reload()
    }

    required init?(coder _: NSCoder) { nil }
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        let dark = isDarkAppearance(self)
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        layer?.backgroundColor = NSColor(white: dark ? 1 : 0, alpha: 0.06).cgColor
        layer?.borderColor = NSColor(white: dark ? 1 : 0, alpha: 0.12).cgColor
    }

    func reload() {
        let path = D.string(forKey: key)
        guard path != loaded else { return }  // 路径没变就不重新解码
        loaded = path
        let opts = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 480] as CFDictionary
        let img = D.string(forKey: key)
            .flatMap { CGImageSourceCreateWithURL(URL(fileURLWithPath: $0) as CFURL, nil) }
            .flatMap { CGImageSourceCreateThumbnailAtIndex($0, 0, opts) }
        layer?.contents = img
        placeholder.isHidden = img != nil
    }

    private func choose() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.image]
        guard p.runModal() == .OK, let u = p.url else { return }
        // 复制一份到应用自己的目录：以后读取不需要"文件与文件夹"权限，原图被移动或删除也不受影响。
        let fm = FileManager.default
        guard let dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.appendingPathComponent("Gloam") else { return }
        let dest = dir.appendingPathComponent("\(key)-\(Int(Date().timeIntervalSince1970)).\(u.pathExtension)")
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try fm.copyItem(at: u, to: dest)
        } catch {
            NSSound.beep()
            return
        }
        if let old = D.string(forKey: key), old.hasPrefix(dir.path) { try? fm.removeItem(atPath: old) }
        D.set(dest.path, forKey: key)
        reload()
    }
}

/// 常用城市（纬度、经度、时区），省得手填。
private let cities: [(name: String, lat: Double, lon: Double, zone: String)] = [
    ("北京", 39.90, 116.40, "Asia/Shanghai"), ("上海", 31.23, 121.47, "Asia/Shanghai"),
    ("广州", 23.13, 113.26, "Asia/Shanghai"), ("深圳", 22.54, 114.06, "Asia/Shanghai"),
    ("成都", 30.57, 104.07, "Asia/Shanghai"), ("杭州", 30.27, 120.15, "Asia/Shanghai"),
    ("武汉", 30.59, 114.31, "Asia/Shanghai"), ("西安", 34.34, 108.94, "Asia/Shanghai"),
    ("香港", 22.32, 114.17, "Asia/Hong_Kong"), ("台北", 25.03, 121.57, "Asia/Taipei"),
    ("东京", 35.68, 139.69, "Asia/Tokyo"), ("首尔", 37.57, 126.98, "Asia/Seoul"),
    ("新加坡", 1.35, 103.82, "Asia/Singapore"), ("悉尼", -33.87, 151.21, "Australia/Sydney"),
    ("伦敦", 51.51, -0.13, "Europe/London"), ("巴黎", 48.86, 2.35, "Europe/Paris"),
    ("柏林", 52.52, 13.40, "Europe/Berlin"), ("纽约", 40.71, -74.01, "America/New_York"),
    ("芝加哥", 41.88, -87.63, "America/Chicago"), ("洛杉矶", 34.05, -118.24, "America/Los_Angeles"),
    ("旧金山", 37.77, -122.42, "America/Los_Angeles"), ("西雅图", 47.61, -122.33, "America/Los_Angeles"),
    ("温哥华", 49.28, -123.12, "America/Vancouver"), ("多伦多", 43.65, -79.38, "America/Toronto"),
]

// MARK: 设置窗口

final class Settings: NSObject, NSWindowDelegate, CLLocationManagerDelegate {
    let window: NSWindow
    private let tabs = Tabs()

    private let badge = NSView(), badgeIcon = NSImageView()
    private let statusTitle = label("", 15, .semibold), statusSub = label("", 12, .regular, .secondaryLabelColor)
    private let modeNote = NSTextField(wrappingLabelWithString: ""), locNote = note(), zoneNote = note(), riseNote = note(), setNote = note(), riseOff = label(), setOff = label()
    private let forecastNote = note(), forecastVerdict = label("", 12, .regular, .secondaryLabelColor)
    private let kelvin = label("", 13, .medium), slider = NSSlider()
    private let warmTime = timePicker("warmTime")
    private let thumbLight = Thumb("wallLight"), thumbDark = Thumb("wallDark")
    private var solar = NSView(), custom = NSView(), zoneSection = NSView()
    private let hotkey = NSButton(title: "", target: nil, action: nil)
    private var monitor: Any?
    private var loc: CLLocationManager?, locStatus = ""
    private var switches: [(key: String, view: NSSwitch, dependents: [NSView])] = []

    override init() {
        window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        super.init()
        tabs.tabStyle = .toolbar
        for item in [schedulePane(), weatherPane(), warmPane(), wallpaperPane(), generalPane()] { tabs.addTabViewItem(item) }
        window.contentViewController = tabs
        window.toolbarStyle = .preference
        window.title = tabs.tabViewItems[0].label
        window.isReleasedWhenClosed = false
        window.delegate = self
        refresh(animate: false)
        window.center()
        window.initialFirstResponder = nil
        DispatchQueue.main.async { [window] in window.makeFirstResponder(nil) }
    }

    func windowDidResignKey(_: Notification) { stopRecording() }

    func windowWillClose(_: Notification) {
        stopRecording()
        window.makeFirstResponder(nil)  // 让正在编辑的输入框先把值写回去
        // 写入落盘并通知常驻进程之后再退出；整个设置进程到此结束。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication)
            Note.post(Note.changed)
            exit(0)
        }
    }

    private func toggle(_ key: String, _ dependents: [NSView] = []) -> NSSwitch {
        let s = on(NSSwitch()) { D.set($0.state == .on, forKey: key) }
        switches.append((key, s, dependents))
        return s
    }

    // MARK: 分页

    private func schedulePane() -> NSTabViewItem {
        badge.wantsLayer = true
        badge.layer?.cornerRadius = 10
        badge.layer?.cornerCurve = .continuous
        badgeIcon.contentTintColor = .white
        badge.addSubview(badgeIcon)
        badgeIcon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            badge.widthAnchor.constraint(equalToConstant: 40), badge.heightAnchor.constraint(equalToConstant: 40),
            badgeIcon.centerXAnchor.constraint(equalTo: badge.centerXAnchor), badgeIcon.centerYAnchor.constraint(equalTo: badge.centerYAnchor),
        ])
        let status = NSStackView()
        status.orientation = .horizontal
        status.addView(stack(.horizontal, [badge, stack(.vertical, [statusTitle, statusSub], 3)], 12), in: .leading)
        status.addView(on(NSButton(title: "立即切换", target: nil, action: nil)) { _ in setDark(!isDark) }, in: .trailing)
        status.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)

        let zone = NSPopUpButton()
        zone.addItems(withTitles: ["系统时区"] + TimeZone.knownTimeZoneIdentifiers)
        bindD(zone, .selectedValue, "tz")
        zone.widthAnchor.constraint(equalToConstant: 190).isActive = true

        func offset(_ key: String, _ text: NSTextField) -> NSView {
            let s = NSStepper()
            s.minValue = -120; s.maxValue = 120; s.increment = 5
            bindD(s, .value, key)
            text.textColor = .secondaryLabelColor
            return stack(.horizontal, [text, s], 6)
        }
        func coordinate(_ key: String, _ hint: String) -> NSTextField {
            let f = NSTextField()
            f.placeholderString = hint
            f.alignment = .right
            f.bind(.value, to: NSUserDefaultsController.shared, withKeyPath: "values." + key, options: [.nullPlaceholder: hint])
            f.widthAnchor.constraint(equalToConstant: 76).isActive = true
            return f
        }
        let city = NSPopUpButton(frame: .zero, pullsDown: true)
        city.addItems(withTitles: ["选择城市"] + cities.map { $0.name })
        on(city) { [unowned self] p in
            let i = p.indexOfSelectedItem - 1
            guard cities.indices.contains(i) else { return }
            D.set(cities[i].lat, forKey: "lat"); D.set(cities[i].lon, forKey: "lon")
            D.set(cities[i].zone, forKey: "tz")  // 时间也按这座城市的时区显示
            self.locDone("已设为" + cities[i].name)
        }
        locNote.lineBreakMode = .byTruncatingTail
        locNote.widthAnchor.constraint(equalToConstant: 190).isActive = true
        for l in [modeNote] {
            l.font = .systemFont(ofSize: 11); l.textColor = .secondaryLabelColor; l.isSelectable = false
        }

        // 每种方式只显示自己用得到的选项。
        let modes = section("切换方式", [row("自动切换", nil, segmented(["日出日落", "自定义时间", "手动"], "mode"))])
        modes.addArrangedSubview(modeNote)
        modeNote.widthAnchor.constraint(equalTo: modes.widthAnchor, constant: -12).isActive = true
        solar = section("日出日落", [
            row("位置", locNote, stack(.horizontal, [city, on(NSButton(title: "定位", target: nil, action: nil)) { [unowned self] _ in self.locate() }], 6)),
            row("经纬度", note("也可以手动填写"), stack(.horizontal, [coordinate("lat", "纬度"), coordinate("lon", "经度")], 6)),
            row("日出时转为浅色", riseNote, offset("riseOff", riseOff)),
            row("日落时转为深色", setNote, offset("setOff", setOff)),
        ])
        custom = section("自定义时间", [
            row("转为浅色", nil, timePicker("lightTime")),
            row("转为深色", nil, timePicker("darkTime")),
        ])
        zoneSection = section("时区", [row("时区", zoneNote, zone)], footer: "时间按所选时区显示和计算，不会改动系统时区。")
        return pane("日程", "clock", [section(nil, [status]), modes, solar, custom, zoneSection])
    }

    private func weatherPane() -> NSTabViewItem {
        let level = segmented(["多云", "阴天", "阴沉"], "level"), unit = segmented(["°C", "°F"], "fahrenheit")
        return pane("天气", "cloud.sun", [
            section(nil, [
                row("阴天提前转为深色", note("云层够厚时，当天提早进入深色"), toggle("weather", [level, unit])),
                row("灵敏度", note("云量达到 70% / 85% / 95% 时触发"), level),
                row("温度单位", nil, unit),
            ]),
            section("今天", [row("预报", forecastNote, forecastVerdict)],
                    footer: "数据来自 Open-Meteo：每天只请求一次，只发送精确到约 1 公里的坐标。每天最多提前一次，不会来回跳。"),
        ])
    }

    private func warmPane() -> NSTabViewItem {
        slider.cell = WarmCell()
        slider.minValue = 1900; slider.maxValue = 6500
        slider.isContinuous = true
        on(slider) { [unowned self] s in
            let k = (s.doubleValue / 50).rounded() * 50
            D.set(k, forKey: "kelvin")
            self.kelvin.stringValue = "\(Int(k))K"
            Note.post(Note.preview, String(Int(k)))  // 色温由常驻进程负责：请它预览 3 秒
        }
        let head = NSStackView()
        head.addView(label("色温"), in: .leading)
        head.addView(kelvin, in: .trailing)
        let ends = NSStackView()
        ends.addView(note("烛光 1900K"), in: .leading)
        ends.addView(note("日光 6500K"), in: .trailing)
        let temperature = stack(.vertical, [head, slider, ends], 6)
        temperature.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        for v in [head, slider, ends] as [NSView] {
            v.widthAnchor.constraint(equalTo: temperature.widthAnchor, constant: -28).isActive = true
        }
        let start = segmented(["日落", "定时", "全天"], "warmMode")
        return pane("暖色", "sun.dust", [
            section(nil, [
                row("暖色屏幕", note("降低色温，减少夜间蓝光"), toggle("warm", [slider, start, warmTime])),
                temperature,
                row("开始时间", nil, stack(.horizontal, [warmTime, start], 8)),
            ], footer: "日出时自动恢复，起止各有 30 分钟渐变。生效期间会暂时接管 Night Shift，结束后原样交还。"),
        ])
    }

    private func wallpaperPane() -> NSTabViewItem {
        func captioned(_ t: Thumb, _ s: String) -> NSView {
            let v = stack(.vertical, [t, note(s)], 6)
            v.alignment = .centerX
            return v
        }
        let pair = stack(.horizontal, [captioned(thumbLight, "浅色外观"), captioned(thumbDark, "深色外观")], 12)
        pair.alignment = .top
        pair.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 12, right: 14)
        return pane("壁纸", "photo", [
            section(nil, [
                row("随外观更换壁纸", note("所有显示器一起更换"), toggle("wall", [thumbLight, thumbDark])),
                pair,
            ]),
        ])
    }

    private func generalPane() -> NSTabViewItem {
        hotkey.title = D.string(forKey: "hkName") ?? ""
        on(hotkey) { [unowned self] _ in self.monitor == nil ? self.record() : self.stopRecording() }
        let login = on(NSSwitch()) { s in
            let want = s.state == .on
            if want { try? SMAppService.mainApp.register() } else { try? SMAppService.mainApp.unregister() }
            let status = SMAppService.mainApp.status
            // 用户在系统设置里关掉过的话，应用自己没法重新启用，直接带他去登录项那一页。
            if want, status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
            s.state = status == .enabled ? .on : .off
        }
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off

        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.widthAnchor.constraint(equalToConstant: 44).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 44).isActive = true
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let about = NSStackView()
        about.addView(stack(.horizontal, [icon, stack(.vertical, [label("Gloam", 14, .semibold), note("版本 \(version) · 极简的自动深浅色工具")], 3)], 12), in: .leading)
        about.addView(on(NSButton(title: "退出 Gloam", target: nil, action: nil)) { _ in Note.post(Note.quit); exit(0) }, in: .trailing)
        about.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        return pane("通用", "gearshape", [
            section(nil, [
                row("切换外观快捷键", note("在任何应用里按下即可切换"), hotkey),
                row("登录时启动", nil, login),
                row("显示菜单栏图标", note("关闭后常驻内存最低；再次打开 Gloam 即可进入设置"), toggle("showIcon")),
            ]),
            section(nil, [about]),
        ])
    }

    // MARK: 状态刷新（设置变化、外观变化时调用）

    func refresh(animate: Bool = true) {
        let now = Date(), dark = isDark, mode = D.integer(forKey: "mode")
        let f = DateFormatter()
        f.timeStyle = .short
        f.timeZone = cal.timeZone

        badge.layer?.backgroundColor = (dark ? NSColor.systemIndigo : NSColor.systemOrange).cgColor
        badgeIcon.image = symbol(dark ? "moon.stars.fill" : "sun.max.fill", 20, .medium)
        statusTitle.stringValue = dark ? "当前为深色外观" : "当前为浅色外观"
        statusSub.stringValue = nextSwitch(now)
        modeNote.stringValue = ["每天按所在位置的日出、日落时间切换，时间会随日期自动变化。", "每天在固定的时间切换。",
                                "不自动切换，只用菜单栏图标或快捷键手动切换。"][min(2, max(0, mode))]

        zoneNote.stringValue = "该时区现在 " + f.string(from: now)
        let located = coord() != nil, today = schedule(cal.startOfDay(for: now))
        riseNote.stringValue = today.map { "今天 " + f.string(from: $0.light) } ?? "设置位置后生效"
        setNote.stringValue = today.map { "今天 " + f.string(from: $0.dark) } ?? "设置位置后生效"
        for (key, text) in [("riseOff", riseOff), ("setOff", setOff)] {
            let m = D.integer(forKey: key)
            text.stringValue = m == 0 ? "准时" : m < 0 ? "提前 \(-m) 分钟" : "延后 \(m) 分钟"
        }
        locNote.stringValue = !locStatus.isEmpty ? locStatus : located ? "只在本机用来计算" : "选一个城市，或点定位"
        solar.isHidden = mode != 0
        custom.isHidden = mode != 1
        zoneSection.isHidden = mode == 2

        if !D.bool(forKey: "weather") {
            forecastNote.stringValue = "未开启"; forecastVerdict.stringValue = ""
        } else if let line = weatherLine(now) {
            forecastNote.stringValue = line
            forecastVerdict.stringValue = today.flatMap { weatherDark(now, $0.light, $0.dark) }.map { f.string(from: $0) + " 起提前转深色" } ?? "今天不提前"
        } else {
            forecastNote.stringValue = located ? "正在获取…" : "需要先在「日程」里设置位置"; forecastVerdict.stringValue = ""
        }

        let k = D.double(forKey: "kelvin")
        slider.doubleValue = k
        kelvin.stringValue = "\(Int(k))K"
        warmTime.isHidden = D.integer(forKey: "warmMode") != 1
        thumbLight.reload(); thumbDark.reload()

        for s in switches {
            let isOn = D.bool(forKey: s.key)
            s.view.state = isOn ? .on : .off
            for v in s.dependents {
                if let c = v as? NSControl { c.isEnabled = isOn } else { v.alphaValue = isOn ? 1 : 0.45 }
            }
        }
        tabs.fit(animate: animate)
    }

    // MARK: 定位（只在用户点"定位"时取一次，精确到约 1 公里）

    /// 先确认授权，再取一次位置；每一步的结果都写进 locStatus 显示在"位置"那一行。
    private func locate() {
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(authTimeout), object: nil)
        let m = CLLocationManager()
        m.delegate = self
        m.desiredAccuracy = kCLLocationAccuracyThreeKilometers
        loc = m
        proceed(m)
    }

    /// 按当前授权状态走下一步（系统不一定会主动回调初始状态，所以这里主动查）。
    private func proceed(_ m: CLLocationManager) {
        switch m.authorizationStatus {
        case .notDetermined:
            locStatus = "请在系统弹窗里允许定位"
            m.requestWhenInUseAuthorization()  // 用户选择后会回调 didChangeAuthorization
            m.requestLocation()                // macOS 上要真正请求一次位置，授权框才会弹出
            perform(#selector(authTimeout), with: nil, afterDelay: 120)
        case .denied, .restricted:
            // 区分"系统总开关没开"和"只是没给 Gloam 权限"；这个查询可能阻塞，放到后台线程。
            DispatchQueue.global().async {
                let enabled = CLLocationManager.locationServicesEnabled()
                DispatchQueue.main.async {
                    self.locDone(enabled ? "没有定位权限，请在系统设置里允许" : "系统定位服务未开启")
                    if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") {
                        NSWorkspace.shared.open(u)
                    }
                }
            }
        default:
            locStatus = "正在定位…"
            m.requestLocation()
        }
        refresh()
    }

    func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        guard m === loc, m.authorizationStatus != .notDetermined else { return }
        proceed(m)
    }

    func locationManager(_: CLLocationManager, didUpdateLocations l: [CLLocation]) {
        guard let c = l.last?.coordinate else { return }
        D.set((c.latitude * 100).rounded() / 100, forKey: "lat")
        D.set((c.longitude * 100).rounded() / 100, forKey: "lon")
        locDone("已定位")
    }

    func locationManager(_: CLLocationManager, didFailWithError e: Error) {
        guard let m = loc else { return }
        if (e as? CLError)?.code == .denied {
            if m.authorizationStatus != .notDetermined { proceed(m) }  // 还在等用户回答授权框时先不管
            return
        }
        locDone("定位失败，请确认 Wi-Fi 已打开")
    }

    /// 授权框两分钟没有结果（被忽略或没弹出来）就结束等待，免得状态一直挂着。
    @objc private func authTimeout() {
        if loc?.authorizationStatus == .notDetermined { locDone("没有收到授权结果，可以直接选城市") }
    }

    private func locDone(_ s: String) {
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(authTimeout), object: nil)
        locStatus = s
        loc = nil
        refresh()
    }

    // MARK: 快捷键录制

    /// 开始录制：下一次带修饰键的按键成为新快捷键。录制期间的监听器在 stopRecording() 里一定会被移除。
    private func record() {
        hotkey.title = "按下组合键…（Esc 取消，⌫ 清除）"
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [unowned self] e in
            let f = e.modifierFlags
            if e.keyCode == UInt16(kVK_Delete) {
                D.set(0, forKey: "hkMods"); D.set("未设置", forKey: "hkName")
            } else if e.keyCode != UInt16(kVK_Escape) {
                guard !f.intersection([.command, .option, .control]).isEmpty else { return nil }
                var m = 0, s = ""
                for (flag, carbon, sym) in [(NSEvent.ModifierFlags.control, controlKey, "⌃"), (.option, optionKey, "⌥"),
                                            (.shift, shiftKey, "⇧"), (.command, cmdKey, "⌘")] where f.contains(flag) {
                    m |= carbon; s += sym
                }
                D.set(Int(e.keyCode), forKey: "hkCode"); D.set(m, forKey: "hkMods")
                D.set(s + (e.charactersIgnoringModifiers ?? "").uppercased(), forKey: "hkName")
            }
            self.stopRecording()  // 新快捷键写进设置后，常驻进程会收到通知并重新注册
            return nil
        }
    }

    private func stopRecording() {
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        hotkey.title = D.string(forKey: "hkName") ?? ""
    }
}

// MARK: 设置进程的入口

final class SettingsApp: NSObject, NSApplicationDelegate {
    private var settings: Settings!

    func applicationDidFinishLaunching(_: Notification) {
        // 没有菜单栏的后台应用也需要主菜单，否则输入框里 ⌘C/⌘V、⌘W 都不起作用。
        let main = NSMenu(), edit = NSMenu(title: "编辑")
        for (title, sel, key) in [("关闭窗口", #selector(NSWindow.performClose(_:)), "w"), ("剪切", #selector(NSText.cut(_:)), "x"),
                                  ("拷贝", #selector(NSText.copy(_:)), "c"), ("粘贴", #selector(NSText.paste(_:)), "v"),
                                  ("全选", #selector(NSText.selectAll(_:)), "a")] {
            edit.addItem(withTitle: title, action: sel, keyEquivalent: key)
        }
        main.addItem(withTitle: "编辑", action: nil, keyEquivalent: "").submenu = edit
        NSApp.mainMenu = main

        settings = Settings()
        NotificationCenter.default.addObserver(self, selector: #selector(changed), name: UserDefaults.didChangeNotification, object: nil)
        Note.observe("AppleInterfaceThemeChangedNotification", self, #selector(external))
        Note.observe(Note.state, self, #selector(external))
        Note.observe(Note.show, self, #selector(show))
        Note.observe(Note.quit, self, #selector(quit))
        show()
    }

    func applicationShouldHandleReopen(_: NSApplication, hasVisibleWindows _: Bool) -> Bool { show(); return false }

    @objc private func show() {
        NSApp.activate(ignoringOtherApps: true)
        settings.window.makeKeyAndOrderFront(nil)
    }

    /// 本进程改了设置：稍等合并一下，然后落盘、通知常驻进程、刷新界面。
    @objc private func changed() {
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(settled), object: nil)
        perform(#selector(settled), with: nil, afterDelay: 0.15)
    }

    @objc private func settled() {
        CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication)
        Note.post(Note.changed)
        // 常驻进程收到通知后可能会切外观、更新"下次切换"等，稍后再刷新一次界面。
        settings.refresh()
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(refreshLater), object: nil)
        perform(#selector(refreshLater), with: nil, afterDelay: 0.8)
    }

    /// 外观变了，或常驻进程更新了天气等状态。
    @objc private func external() {
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(refreshLater), object: nil)
        perform(#selector(refreshLater), with: nil, afterDelay: 0.3)
    }

    @objc private func refreshLater() {
        CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication)
        settings.refresh()
    }

    @objc private func quit() { exit(0) }
}

func runSettings() -> Never {
    // 设置窗口已经开着：让它到前面来，这个进程直接退出。
    guard acquire("settings.lock") else { Note.post(Note.show); exit(0) }
    let delegate = SettingsApp()
    NSApplication.shared.delegate = delegate
    NSApp.setActivationPolicy(.accessory)
    NSApp.run()
    exit(0)
}

func printPermissions() {
    let names = ["未询问", "受限", "已拒绝", "已允许", "已允许（使用期间）"]
    let a = Int(CLLocationManager().authorizationStatus.rawValue)
    print("定位授权:", names.indices.contains(a) ? names[a] : "未知(\(a))")
    print("系统定位服务:", CLLocationManager.locationServicesEnabled() ? "开" : "关")
    let l = ["未注册", "已启用", "需要在系统设置里批准", "未找到"], st = SMAppService.mainApp.status.rawValue
    print("登录时启动:", l.indices.contains(st) ? l[st] : "未知(\(st))")
    print("已保存位置:", coord() == nil ? "无" : "有", "· 天气联网:", D.bool(forKey: "weather") ? "开" : "关")
}
