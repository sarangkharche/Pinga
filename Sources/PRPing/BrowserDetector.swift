import AppKit
import ApplicationServices
import PRPingCore

// Reads only the focused browser window's URL and accessibility roles.
enum BrowserDetector {
    static let browsers: Set<String> = ["wang.zigao.zigzag", "com.apple.Safari", "com.google.Chrome", "org.mozilla.firefox", "com.microsoft.edgemac", "com.brave.Browser"]

    static func browserPID() -> pid_t? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let id = app.bundleIdentifier, browsers.contains(id) else { return nil }
        return app.processIdentifier
    }

    static func currentPR(pid: pid_t, scope: WatchScope) -> BrowserPR? {
        guard AXIsProcessTrusted() else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.15)
        guard let window = element(app, kAXFocusedWindowAttribute as CFString) else { return nil }
        if let url = url(window), let result = BrowserPR.parse(url, scope: scope) { return result }
        var budget = 100
        return findWebArea(window, scope: scope, depth: 0, budget: &budget)
    }

    private static func findWebArea(_ element: AXUIElement, scope: WatchScope, depth: Int, budget: inout Int) -> BrowserPR? {
        guard depth < 7 && budget > 0 else { return nil }
        budget -= 1
        var role: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role) == .success,
           (role as? String) == "AXWebArea" {
            guard let url = url(element) else { return nil }
            return BrowserPR.parse(url, scope: scope)
        }
        var children: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
              let list = children as? [AXUIElement] else { return nil }
        for child in list {
            if let pr = findWebArea(child, scope: scope, depth: depth + 1, budget: &budget) { return pr }
        }
        return nil
    }

    private static func element(_ parent: AXUIElement, _ attribute: CFString) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(parent, attribute, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func url(_ element: AXUIElement) -> URL? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXURLAttribute as CFString, &value) == .success else { return nil }
        if let url = value as? URL { return url }
        if let value = value as? String {
            return URL(string: value.hasPrefix("github.com/") ? "https://" + value : value)
        }
        return nil
    }
}
