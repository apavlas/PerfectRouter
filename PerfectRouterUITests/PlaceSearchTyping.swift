import XCTest
import Darwin

/// Shared placeSearch typing path for Core Journey, B11, and Highlights smoke.
enum PlaceSearchTyping {
    /// Must match `UITestStubLaunch.focusPlaceSearchNotifyName`.
    static let focusNotifyName = "com.apavlas.PerfectRouter.UITestFocusPlaceSearch"
    /// Must match `UITestPlaceSearchListener.port`.
    static let typePort: in_port_t = 17321

    /// Type into placeSearch. On iPhone, a normal tap and typeText works. On
    /// a 13-inch iPad floating sheet, synthesized taps can be delivered to
    /// the map and typeText reports no keyboard focus, so the fallback asks
    /// the app over loopback to set the query. That path must not make the
    /// field first responder: focusing expands a medium iPad sheet to large
    /// and breaks the map-fit test.
    static func type(
        _ name: String,
        into field: XCUIElement,
        in app: XCUIApplication,
        avoidFocus: Bool = false
    ) {
        // A tap on placeSearch expands an iPad medium sheet to large, even
        // when XCTest never reports keyboard focus. Callers that have locked
        // the medium detent must set the query in-app and skip the tap.
        if !avoidFocus, field.exists {
            field.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.5)).tap()
            if field.hasFocus || app.keyboards.firstMatch.waitForExistence(timeout: 2) {
                field.typeText(name)
                return
            }
        }
        postTypeRequest(name)
        let deadline = Date().addingTimeInterval(4)
        while Date() < deadline {
            let value = (field.value as? String) ?? ""
            if value.contains(name) { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        field.typeText(name)
    }

    static func focus(_ field: XCUIElement, in app: XCUIApplication) {
        if field.exists {
            field.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.5)).tap()
            if app.keyboards.firstMatch.waitForExistence(timeout: 2) { return }
            if field.hasFocus { return }
        }
        // Used only when a test needs the keyboard itself. Do not call this
        // from type(): becoming first responder expands the iPad sheet.
        postFocusRequest()
        RunLoop.current.run(until: Date().addingTimeInterval(0.35))
        _ = app.keyboards.firstMatch.waitForExistence(timeout: 3)
    }

    static func postFocusRequest() {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(focusNotifyName as CFString),
            nil,
            nil,
            true
        )
    }

    /// Raw TCP, not HTTP/URLSession, so ATS in the test runner cannot block it.
    static func postTypeRequest(_ name: String) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            print("PLACESEARCH socket failed")
            return
        }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = typePort.bigEndian
        inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr)
        let rc = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                connect(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard rc == 0 else {
            print("PLACESEARCH connect failed errno=\(errno)")
            return
        }
        var payload = Array("TYPE \(name)\n".utf8)
        let written = payload.withUnsafeBytes { raw in
            write(fd, raw.baseAddress, payload.count)
        }
        _ = Darwin.shutdown(fd, SHUT_WR)
        print("PLACESEARCH wrote \(written) bytes")
        // Give the app a moment to read before we close.
        usleep(200_000)
    }
}
