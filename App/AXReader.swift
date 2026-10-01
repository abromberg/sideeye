import AppKit
import ApplicationServices

/// Accessibility reads. All functions take a pid and build their own elements so results are plain Sendable values.
enum AX {
    static let chromiumBrowsers: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.canary", "company.thebrowser.Browser",
        "com.brave.Browser", "com.microsoft.edgemac", "com.vivaldi.Vivaldi", "com.operasoftware.Opera",
        "org.chromium.Chromium", "company.thebrowser.dia", "net.imput.helium",
    ]

    static func isTrusted(prompt: Bool = false) -> Bool {
        let opts = ["AXTrustedCheckOptionPrompt": prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
    }

    static func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    static func attribute(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &value) == .success else { return nil }
        return value
    }

    static func string(_ el: AXUIElement, _ name: String) -> String? {
        attribute(el, name) as? String
    }

    static func children(_ el: AXUIElement) -> [AXUIElement] {
        (attribute(el, kAXChildrenAttribute) as? [AXUIElement]) ?? []
    }

    static func app(_ pid: pid_t) -> AXUIElement {
        let el = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(el, 0.5)
        return el
    }

    static func focusedWindow(_ pid: pid_t) -> AXUIElement? {
        guard let v = attribute(app(pid), kAXFocusedWindowAttribute) else { return nil }
        return (v as! AXUIElement)
    }

    static func windowTitle(_ pid: pid_t) -> String {
        focusedWindow(pid).flatMap { string($0, kAXTitleAttribute) } ?? ""
    }

    /// Chrome and Electron apps expose an empty tree until asked. Chromium browsers honor AXEnhancedUserInterface;
    /// Electron honors AXManualAccessibility. We avoid AXEnhancedUserInterface elsewhere since it slows window animations.
    static func enableEnhancedTree(pid: pid_t, bundleID: String) {
        let el = app(pid)
        AXUIElementSetAttributeValue(el, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        if chromiumBrowsers.contains(bundleID) {
            AXUIElementSetAttributeValue(el, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        }
    }

    static let browsers: Set<String> = chromiumBrowsers.union([
        "com.apple.Safari", "com.apple.SafariTechnologyPreview", "org.mozilla.firefox", "app.zen-browser.zen",
        "com.kagi.kagimacOS",
    ])

    /// Browser URL from the first AXWebArea's AXURL (Safari, Chromium with the enhanced tree on), falling back to the
    /// address bar. Only for known browsers and http(s) — Electron apps expose internal `app://` web areas.
    static func browserURL(_ pid: pid_t, bundleID: String) -> String? {
        guard browsers.contains(bundleID), let window = focusedWindow(pid) else { return nil }
        var queue = [window]
        var visited = 0
        var addressBar: String?
        while !queue.isEmpty, visited < 400 {
            let el = queue.removeFirst()
            visited += 1
            let role = string(el, kAXRoleAttribute)
            if role == "AXWebArea" {
                if let url = attribute(el, "AXURL"), CFGetTypeID(url) == CFURLGetTypeID() {
                    let s = (url as! CFURL as URL).absoluteString
                    if s.hasPrefix("http") { return s }
                }
                continue // don't descend into page content looking for the URL
            }
            if addressBar == nil, role == kAXTextFieldRole,
               let desc = string(el, kAXDescriptionAttribute)?.lowercased(),
               desc.contains("address") || desc.contains("search") || desc.contains("url"),
               let value = string(el, kAXValueAttribute), !value.isEmpty, !value.contains(" "), value.contains(".") {
                addressBar = value.contains("://") ? value : value.hasPrefix("/") ? "file://\(value)" : "https://\(value)"
            }
            queue.append(contentsOf: children(el))
        }
        return addressBar
    }

    /// Screen frame (global, top-left origin — the same space as `SCWindow.frame`) of the browser's page area, so a
    /// screenshot can leave out the tab strip and toolbar. Other tabs' titles there say nothing about this page.
    static func webAreaFrame(_ pid: pid_t, bundleID: String) -> CGRect? {
        guard browsers.contains(bundleID), let window = focusedWindow(pid),
              let web = firstDescendant(of: window, role: "AXWebArea"),
              let pos = attribute(web, kAXPositionAttribute), CFGetTypeID(pos) == AXValueGetTypeID(),
              let size = attribute(web, kAXSizeAttribute), CFGetTypeID(size) == AXValueGetTypeID()
        else { return nil }
        var origin = CGPoint.zero, extent = CGSize.zero
        guard AXValueGetValue(pos as! AXValue, .cgPoint, &origin), AXValueGetValue(size as! AXValue, .cgSize, &extent),
              extent.width > 100, extent.height > 100
        else { return nil }
        return CGRect(origin: origin, size: extent)
    }

    private static let textRoles: Set<String> = [
        "AXStaticText", "AXTextArea", "AXTextField", "AXHeading", "AXLink", "AXButton", "AXCell", "AXMenuItem",
    ]
    /// Browser/app chrome whose text (tabs, bookmarks, menus) says nothing about the content.
    private static let chromeRoles: Set<String> = ["AXToolbar", "AXMenuBar", "AXTabGroup", "AXSecureTextField"]

    /// Text that describes what the user is working on, most specific source first:
    /// 1. a large focused editor (the document being typed in),
    /// 2. the page's main landmark, in browsers and web-based apps: the open email or conversation without the sidebar,
    ///    which otherwise filled the cap first (Gmail's labels and contacts, Slack's channel list),
    /// 3. in browsers, the page's web area (not tabs or bookmarks),
    /// 4. any focused editor, even a short one — sidebars and file lists around it are noise,
    /// 5. the longest text area in the window (apps like Obsidian often report no focused element),
    /// 6. the whole window, minus toolbars and menus.
    static func visibleText(_ pid: pid_t, bundleID: String, cap: Int = 3_000) -> String {
        guard let window = focusedWindow(pid) else { return "" }
        let editor = focusedEditorText(pid, cap: cap)
        if let editor, editor.count >= 200 { return editor }
        if let main = mainLandmark(in: window) {
            let text = collectText(main, cap: cap)
            if text.count >= 200 { return text }
        }
        if browsers.contains(bundleID), let web = firstDescendant(of: window, role: "AXWebArea") {
            let page = collectText(web, cap: cap)
            if !page.isEmpty { return page }
        }
        if let editor, !editor.isEmpty { return editor }
        if let area = longestTextArea(in: window) { return String(area.prefix(cap)) }
        return collectText(window, cap: cap)
    }

    /// Value of the focused text area, windowed around the cursor so long documents and terminals show what's current.
    static func focusedEditorText(_ pid: pid_t, cap: Int) -> String? {
        guard let f = attribute(app(pid), kAXFocusedUIElementAttribute) else { return nil }
        let el = f as! AXUIElement
        let role = string(el, kAXRoleAttribute)
        guard role == "AXTextArea" || role == "AXTextField",
              let value = string(el, kAXValueAttribute)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty
        else { return nil }
        // Skip single-line fields like address and search bars unless they hold real content.
        if role == "AXTextField", value.count < 40 { return nil }
        guard value.count > cap else { return value }
        var cursor = value.count
        if let r = attribute(el, kAXSelectedTextRangeAttribute), CFGetTypeID(r) == AXValueGetTypeID() {
            var range = CFRange()
            if AXValueGetValue(r as! AXValue, .cfRange, &range) { cursor = min(range.location, value.count) }
        }
        let start = max(0, min(cursor - cap / 2, value.count - cap))
        let from = value.index(value.startIndex, offsetBy: start)
        return String(value[from...].prefix(cap))
    }

    static func longestTextArea(in root: AXUIElement, budget: Int = 1_500) -> String? {
        var best: String?
        var stack = [root]
        var visited = 0
        while let el = stack.popLast(), visited < budget {
            visited += 1
            if string(el, kAXRoleAttribute) == "AXTextArea",
               let v = string(el, kAXValueAttribute)?.trimmingCharacters(in: .whitespacesAndNewlines),
               v.count > (best?.count ?? 0) {
                best = v
                continue
            }
            stack.append(contentsOf: children(el))
        }
        return best
    }

    /// The first element marked as the page's main content (ARIA `role="main"`), in reading order.
    static func mainLandmark(in root: AXUIElement, budget: Int = 2_000) -> AXUIElement? {
        var stack = [root]
        var visited = 0
        while let el = stack.popLast(), visited < budget {
            visited += 1
            if string(el, kAXSubroleAttribute) == "AXLandmarkMain" { return el }
            if chromeRoles.contains(string(el, kAXRoleAttribute) ?? "") { continue }
            stack.append(contentsOf: children(el).reversed())
        }
        return nil
    }

    static func firstDescendant(of root: AXUIElement, role wanted: String, budget: Int = 400) -> AXUIElement? {
        var queue = [root]
        var visited = 0
        while !queue.isEmpty, visited < budget {
            let el = queue.removeFirst()
            visited += 1
            if string(el, kAXRoleAttribute) == wanted { return el }
            queue.append(contentsOf: children(el))
        }
        return nil
    }

    /// Depth-first text of a subtree, capped. Skips chrome and secure fields.
    static func collectText(_ root: AXUIElement, cap: Int, nodeBudget: Int = 2_500, timeBudget: TimeInterval = 0.8) -> String {
        let deadline = Date().addingTimeInterval(timeBudget)
        var out: [String] = []
        var total = 0
        var seen = Set<String>()
        var stack = [root]
        var visited = 0
        while let el = stack.popLast(), visited < nodeBudget, total < cap, Date() < deadline {
            visited += 1
            let role = string(el, kAXRoleAttribute) ?? ""
            if chromeRoles.contains(role) { continue }
            if textRoles.contains(role) {
                for attr in [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute] {
                    if let s = string(el, attr)?.trimmingCharacters(in: .whitespacesAndNewlines),
                       s.count > 1, seen.insert(s).inserted {
                        out.append(s)
                        total += s.count + 1
                        break
                    }
                }
            }
            stack.append(contentsOf: children(el).reversed())
        }
        return String(out.joined(separator: "\n").prefix(cap))
    }
}

/// Watches one app's focused-window and title changes. Rebuilt whenever the frontmost app changes.
@MainActor
final class AXAppObserver {
    private var observer: AXObserver?
    private var appElement: AXUIElement?
    private var windowElement: AXUIElement?
    private let onChange: @MainActor () -> Void

    init?(pid: pid_t, onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
        var obs: AXObserver?
        let callback: AXObserverCallback = { _, _, _, refcon in
            guard let refcon else { return }
            let me = Unmanaged<AXAppObserver>.fromOpaque(refcon).takeUnretainedValue()
            MainActor.assumeIsolated { me.fired() }
        }
        guard AXObserverCreate(pid, callback, &obs) == .success, let obs else { return nil }
        observer = obs
        let app = AX.app(pid)
        appElement = app
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for n in [kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification, kAXTitleChangedNotification] {
            AXObserverAddNotification(obs, app, n as CFString, refcon)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
        watchFocusedWindow()
    }

    private func fired() {
        watchFocusedWindow()
        onChange()
    }

    /// Title changes are posted by the window element; re-attach to whichever window is focused now.
    private func watchFocusedWindow() {
        guard let observer, let appElement else { return }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &value) == .success,
              let value else { return }
        let window = value as! AXUIElement
        if let windowElement, CFEqual(windowElement, window) { return }
        if let windowElement {
            AXObserverRemoveNotification(observer, windowElement, kAXTitleChangedNotification as CFString)
        }
        windowElement = window
        AXObserverAddNotification(observer, window, kAXTitleChangedNotification as CFString,
                                  Unmanaged.passUnretained(self).toOpaque())
    }

    func invalidate() {
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        observer = nil
    }
}
