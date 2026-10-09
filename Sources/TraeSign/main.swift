import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// 菜单栏代理模式：无 Dock 图标，常驻状态栏
app.setActivationPolicy(.accessory)
app.activate(ignoringOtherApps: true)
app.run()
