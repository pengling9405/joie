import ApplicationServices
import CoreGraphics
import Foundation

final class EventTapManager {
    var onFnDown: (@MainActor () -> Void)?
    var onFnUp: (@MainActor () -> Void)?
    var onEscapeDown: (@MainActor () -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var runLoop: CFRunLoop?
    private var thread: Thread?
    private var isFnPressed = false
    private var hasSeenSecondaryFnTrue = false
    private var shouldStop = false
    private let fnKeyCode: Int64 = 63 // kVK_Function
    private let escapeKeyCode: Int64 = 53 // kVK_Escape
    private let debugLoggingEnabled = ProcessInfo.processInfo.environment["JOIE_DEBUG_EVENTTAP"] == "1"

    func start() {
        shouldStop = false

        let accessibilityTrusted = ensureAccessibilityPermission()
        if !accessibilityTrusted {
            print("[joie] 需要辅助功能权限：系统设置 -> 隐私与安全性 -> 辅助功能。")
        }

        let inputMonitoringTrusted = ensureInputMonitoringPermission()
        if !inputMonitoringTrusted {
            print("[joie] 若收不到 Fn 事件，可能还需要开启“输入监控”：系统设置 -> 隐私与安全性 -> 输入监控。")
        }

        if let thread, !thread.isFinished {
            return
        }
        thread = nil

        let thread = Thread { [weak self] in
            self?.startOnCurrentThread()
        }
        thread.name = "joie.eventtap"
        self.thread = thread
        thread.start()
    }

    func stop() {
        shouldStop = true
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let runLoop {
            CFRunLoopStop(runLoop)
        }
        eventTap = nil
        runLoopSource = nil
        runLoop = nil
        thread = nil
        isFnPressed = false
        hasSeenSecondaryFnTrue = false
    }

    private func startOnCurrentThread() {
        runLoop = CFRunLoopGetCurrent()

        let mask: CGEventMask =
            (CGEventMask(1) << CGEventType.flagsChanged.rawValue) |
            (CGEventMask(1) << CGEventType.keyDown.rawValue) |
            (CGEventMask(1) << CGEventType.keyUp.rawValue)

        let callback: CGEventTapCallBack = { proxy, type, event, userInfo in
            guard let userInfo else {
                return Unmanaged.passUnretained(event)
            }

            let manager = Unmanaged<EventTapManager>.fromOpaque(userInfo).takeUnretainedValue()

            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = manager.eventTap {
                    CGEvent.tapEnable(tap: tap, enable: true)
                }
                return Unmanaged.passUnretained(event)
            }

            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)

            switch type {
            case .flagsChanged:
                let eventFnPressed = event.flags.contains(.maskSecondaryFn)
                if manager.debugLoggingEnabled {
                    manager.log("flagsChanged keyCode=\(keyCode) eventSecondaryFn=\(eventFnPressed)")
                }
                if eventFnPressed {
                    manager.hasSeenSecondaryFnTrue = true
                }

                if keyCode == manager.fnKeyCode {
                    if manager.hasSeenSecondaryFnTrue {
                        if eventFnPressed && !manager.isFnPressed {
                            manager.isFnPressed = true
                            manager.log("Fn down (flagsChanged)")
                            manager.invokeOnMain(manager.onFnDown)
                        } else if !eventFnPressed && manager.isFnPressed {
                            manager.isFnPressed = false
                            manager.log("Fn up (flagsChanged)")
                            manager.invokeOnMain(manager.onFnUp)
                        }
                    } else {
                        // Fallback for environments that never set maskSecondaryFn.
                        if manager.isFnPressed {
                            manager.isFnPressed = false
                            manager.log("Fn up (keyCode)")
                            manager.invokeOnMain(manager.onFnUp)
                        } else {
                            manager.isFnPressed = true
                            manager.log("Fn down (keyCode)")
                            manager.invokeOnMain(manager.onFnDown)
                        }
                    }
                    break
                }

            case .keyDown:
                let isAutoRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) == 1
                if keyCode == manager.escapeKeyCode, !isAutoRepeat {
                    manager.log("ESC down")
                    manager.invokeOnMain(manager.onEscapeDown)
                }

                if keyCode == manager.fnKeyCode, !manager.isFnPressed {
                    manager.isFnPressed = true
                    manager.log("Fn down (keyDown)")
                    manager.invokeOnMain(manager.onFnDown)
                }

            case .keyUp:
                if keyCode == manager.fnKeyCode, manager.isFnPressed {
                    manager.isFnPressed = false
                    manager.log("Fn up (keyUp)")
                    manager.invokeOnMain(manager.onFnUp)
                }

            default:
                break
            }

            return Unmanaged.passUnretained(event)
        }

        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        var didPrintTapCreateFailureHint = false

        while !shouldStop {
            let tap =
                CGEvent.tapCreate(
                    tap: .cghidEventTap,
                    place: .headInsertEventTap,
                    options: .listenOnly,
                    eventsOfInterest: mask,
                    callback: callback,
                    userInfo: userInfo
                ) ??
                CGEvent.tapCreate(
                    tap: .cgSessionEventTap,
                    place: .headInsertEventTap,
                    options: .listenOnly,
                    eventsOfInterest: mask,
                    callback: callback,
                    userInfo: userInfo
                )

            guard let tap else {
                if !didPrintTapCreateFailureHint {
                    print("[joie] 无法创建 CGEventTap（请检查：辅助功能权限；若仍无效再检查输入监控）。授权后无需重启，本程序会自动重试。")
                    didPrintTapCreateFailureHint = true
                } else {
                    log("无法创建 CGEventTap，1s 后重试…")
                }

                Thread.sleep(forTimeInterval: 1.0)
                continue
            }

            if debugLoggingEnabled {
                print("[joie] EventTap 已启动")
            }

            eventTap = tap

            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            runLoopSource = source
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)

            CGEvent.tapEnable(tap: tap, enable: true)
            CFRunLoopRun()
            break
        }
    }

    private func log(_ message: String) {
        guard debugLoggingEnabled else { return }
        print("[joie] \(message)")
    }

    private func invokeOnMain(_ action: (@MainActor () -> Void)?) {
        guard let action else { return }
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                action()
            }
        }
    }

    private func ensureAccessibilityPermission() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options: CFDictionary = [key: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    private func ensureInputMonitoringPermission() -> Bool {
        if CGPreflightListenEventAccess() {
            return true
        }
        CGRequestListenEventAccess()
        return CGPreflightListenEventAccess()
    }
}
