import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    self.contentViewController = flutterViewController
    // 画面はスマホ向けの縦長レイアウトなので、縦長のウィンドウで開く
    let size = NSSize(width: 480, height: 860)
    let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    let height = min(size.height, visible.height - 40)
    let origin = NSPoint(x: visible.midX - size.width / 2, y: visible.midY - height / 2)
    self.setFrame(NSRect(origin: origin, size: NSSize(width: size.width, height: height)), display: true)
    self.minSize = NSSize(width: 380, height: 600)
    self.title = "単位ハーネス"

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }
}
