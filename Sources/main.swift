// 他妈的记录器 —— 统计你在微信 / AI 里打了多少个“他妈的”
// 原理：按下回车时读取当前输入框内容（辅助功能接口），
// 若输入框随后被清空（= 消息发出去了）且含脏字，则记一条。

import Cocoa
import ApplicationServices
import ServiceManagement
import Carbon

// MARK: - 匹配

enum Swear {
    /// (统计名, 正则)。顺序决定优先级：长的写前面，避免“他妈的”被拆成“他妈”+“妈的”。
    /// 想加词就往这里加一行。
    static let list: [(String, String)] = [
        ("他妈的", "他[妈媽]的"),
        ("妈的蛋", "[妈媽]的蛋"),
        ("他妈",   "他[妈媽](?![妈媽])"),                     // “他妈妈”不算
        ("妈的",   "(?<![我咱俺姥奶舅姨妈媽])[妈媽]的"),       // “我妈的手机”不算
        ("卧槽",   "卧槽|卧艹"),
        ("握草",   "握草"),
        ("傻逼",   "傻[逼屄]"),
        ("神经病", "神[经經]病"),
        ("贱人",   "[贱賤]人"),
        ("个蛋",   "(?<![一两二三四五六七八九十几每这那半0-9])[个個]蛋(?![糕黄白挞饼卷炒汤羹])"), // “一个蛋”“个蛋糕”不算
    ]

    static let words = list.map(\.0)

    static let regex = try! NSRegularExpression(pattern: list.map { "(\($0.1))" }.joined(separator: "|"))

    static func find(_ text: String) -> [String] {
        regex.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length)).compactMap { m in
            (1...list.count).first { m.range(at: $0).location != NSNotFound }.map { list[$0 - 1].0 }
        }
    }

    /// 只列出有次数的词，按次数排
    static func summary(_ counts: [String: Int], sep: String) -> String {
        counts.sorted { $0.value > $1.value }.map { "\($0.key) \($0.value)" }.joined(separator: sep)
    }
}

// MARK: - 场景

enum Scene: String, Codable {
    case chat = "聊天", ai = "AI", other = "其他"

    static let chatApps = ["微信", "WeChat", "QQ", "Telegram", "信息", "Messages", "Discord",
                           "Slack", "飞书", "Lark", "钉钉", "DingTalk", "WhatsApp", "企业微信", "WeCom"]
    static let aiNames = ["Claude", "ChatGPT", "Cursor", "Copilot", "豆包", "Kimi", "DeepSeek",
                          "Gemini", "通义", "元宝", "Perplexity", "文心", "智谱", "Grok"]
    static let browsers = ["com.google.Chrome", "com.apple.Safari", "com.microsoft.edgemac",
                           "com.brave.Browser", "company.thebrowser.Browser", "org.mozilla.firefox"]

    static func classify(app: String, bundle: String, window: String) -> Scene {
        if chatApps.contains(where: { app.localizedCaseInsensitiveContains($0) }) { return .chat }
        if aiNames.contains(where: { app.localizedCaseInsensitiveContains($0) }) { return .ai }
        if browsers.contains(bundle), aiNames.contains(where: { window.localizedCaseInsensitiveContains($0) }) {
            return .ai
        }
        return .other
    }
}

// MARK: - 存储

struct Record: Codable {
    var ts: Double
    var app: String
    var bundle: String
    var window: String
    var scene: Scene
    var words: [String]
    var text: String?

    var date: Date { Date(timeIntervalSince1970: ts) }
}

final class Store {
    let dir: URL
    let file: URL
    private(set) var records: [Record] = []

    init() {
        dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TMDCounter", isDirectory: true)
        file = dir.appendingPathComponent("records.jsonl")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        load()
    }

    private func load() {
        guard let data = try? String(contentsOf: file, encoding: .utf8) else { return }
        let dec = JSONDecoder()
        records = data.split(separator: "\n").compactMap { try? dec.decode(Record.self, from: Data($0.utf8)) }
    }

    func append(_ r: Record) {
        records.append(r)
        guard var line = try? JSONEncoder().encode(r) else { return }
        line.append(0x0A)
        if let h = try? FileHandle(forWritingTo: file) {
            h.seekToEndOfFile(); h.write(line); try? h.close()
        } else {
            try? line.write(to: file)
        }
    }

    func today() -> [Record] {
        let start = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970
        return records.filter { $0.ts >= start }
    }
}

// MARK: - 读取输入框

struct Snapshot {
    var element: AXUIElement?
    var text: String
    var pid: pid_t
    var app: String
    var bundle: String
    var window: String
}

enum AX {
    static func attr(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success ? v : nil
    }

    static func focusedElement() -> AXUIElement? {
        let sys = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(sys, 0.15)
        if let v = attr(sys, kAXFocusedUIElementAttribute) { return (v as! AXUIElement) }
        // 有些 app 不回应系统级查询，退而从前台 app 查
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let a = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(a, 0.15)
        if let v = attr(a, kAXFocusedUIElementAttribute) { return (v as! AXUIElement) }
        return nil
    }

    static func text(of el: AXUIElement) -> String? {
        if let sub = attr(el, kAXSubroleAttribute) as? String, sub == kAXSecureTextFieldSubrole { return nil }
        return attr(el, kAXValueAttribute) as? String
    }

    static func snapshot() -> Snapshot? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier != Bundle.main.bundleIdentifier,
              let el = focusedElement(),
              let t = text(of: el) else { return nil }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var title = ""
        if let w = attr(axApp, kAXFocusedWindowAttribute) {
            title = (attr(w as! AXUIElement, kAXTitleAttribute) as? String) ?? ""
        }
        return Snapshot(element: el, text: t, pid: app.processIdentifier,
                        app: app.localizedName ?? "?", bundle: app.bundleIdentifier ?? "",
                        window: title)
    }

    /// 排查用：把某个 app 的界面结构写成文本
    static func dump(_ app: NSRunningApplication) -> String {
        let a = AXUIElementCreateApplication(app.processIdentifier)
        var out = "app: \(app.localizedName ?? "?") \(app.bundleIdentifier ?? "")\n"
        if let f = attr(a, kAXFocusedUIElementAttribute) {
            let e = f as! AXUIElement
            out += "focused: \(attr(e, kAXRoleAttribute) ?? "?" as CFString) value=\(attr(e, kAXValueAttribute).map { "\($0)" } ?? "nil")\n"
        } else { out += "focused: nil\n" }
        var n = 0
        func walk(_ e: AXUIElement, _ d: Int) {
            n += 1; if n > 600 || d > 30 { return }
            let role = attr(e, kAXRoleAttribute) as? String ?? "?"
            let t = [kAXTitleAttribute, kAXDescriptionAttribute, kAXIdentifierAttribute]
                .compactMap { attr(e, $0) as? String }.filter { !$0.isEmpty }.joined(separator: " / ")
            let v = attr(e, kAXValueAttribute).map { String("\($0)".prefix(60)) } ?? ""
            let foc = (attr(e, kAXFocusedAttribute) as? Bool) == true ? " [FOCUSED]" : ""
            out += String(repeating: "  ", count: d) + "\(role) \(t.prefix(40)) | \(v)\(foc)\n"
            for c in (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] { walk(c, d + 1) }
        }
        for w in (attr(a, kAXWindowsAttribute) as? [AXUIElement]) ?? [] { walk(w, 0) }
        return out + "nodes: \(n)\n"
    }

    /// Electron / Chromium / 一些自绘界面的 app 默认不暴露输入框内容，需要“叫醒”它们
    static func wake(_ app: NSRunningApplication) {
        let a = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetAttributeValue(a, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        let b = app.bundleIdentifier ?? ""
        if Scene.browsers.contains(b) || b == "com.tencent.xinWeChat" {
            AXUIElementSetAttributeValue(a, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        }
    }
}

// MARK: - 监听

final class Monitor {
    var onHit: ((Snapshot, [String]) -> Void)?
    var paused = false
    private var tap: CFMachPort?
    private var lastPolled: (Snapshot, Date)?
    private var pollTimer: Timer?

    var running: Bool { tap != nil }

    func start() -> Bool {
        if tap != nil { return true }
        guard AXIsProcessTrusted() else { return false }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                        options: .defaultTap, eventsOfInterest: mask,
                                        callback: tapCallback, userInfo: nil) else { return false }
        tap = t
        let src = CFMachPortCreateRunLoopSource(nil, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)

        // 兜底：定时缓存输入框内容，万一回车那一刻读不到就用缓存
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in
            guard let self, !self.paused, let s = AX.snapshot(), !s.text.isEmpty else { return }
            self.lastPolled = (s, Date())
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { n in
            if let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication { AX.wake(app) }
        }
        if let app = NSWorkspace.shared.frontmostApplication { AX.wake(app) }
        return true
    }

    func reenable() { if let tap { CGEvent.tapEnable(tap: tap, enable: true) } }

    // MARK: 微信专用：读不到输入框，就在回车前“全选+复制”一下

    /// 这些 app 不暴露输入框内容（微信 4.x），改用复制的办法
    static let copyApps: Set<String> = ["com.tencent.xinWeChat"]
    private let marker: Int64 = 0x746D64   // 标记自己发出的按键，避免被自己再拦一次
    private var composing = false          // 拼音还没上屏
    private var busy = false

    /// 在 tap 里调用。返回 false = 吞掉这个按键（稍后由我们自己补发）
    func handleKey(_ event: CGEvent) -> Bool {
        if event.getIntegerValueField(.eventSourceUserData) == marker { return true }
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        guard code == 36 || code == 76 else { trackComposing(event, code); return true }
        let wasComposing = composing
        composing = false
        guard !paused else { return true }

        let front = NSWorkspace.shared.frontmostApplication
        guard let app = front, let b = app.bundleIdentifier, Monitor.copyApps.contains(b) else {
            onEnter(); return true
        }
        let mods: CGEventFlags = [.maskCommand, .maskShift, .maskAlternate, .maskControl]
        // 带修饰键的回车（换行）、拼音上屏的回车、上一次还没处理完：都直接放行
        guard event.flags.intersection(mods).isEmpty, !wasComposing, !busy else { return true }
        busy = true
        DispatchQueue.main.async { self.copyThenSend(app, key: CGKeyCode(code)) }
        return false
    }

    private func trackComposing(_ event: CGEvent, _ code: Int64) {
        if event.flags.contains(.maskCommand) || event.flags.contains(.maskControl) { return }
        let ch = NSEvent(cgEvent: event)?.charactersIgnoringModifiers ?? ""
        if ch.count == 1, let c = ch.unicodeScalars.first, CharacterSet.lowercaseLetters.contains(c), c.isASCII {
            if Monitor.isInputMethod() { composing = true }
        } else if code == 49 || code == 53 || ch.first?.isNumber == true || ch.first?.isPunctuation == true {
            composing = false   // 空格 / Esc / 数字选词 / 标点 → 上屏了
        }
    }

    static func isInputMethod() -> Bool {
        guard let src = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let p = TISGetInputSourceProperty(src, kTISPropertyInputSourceType) else { return false }
        let type = Unmanaged<CFString>.fromOpaque(p).takeUnretainedValue() as String
        return type == (kTISTypeKeyboardInputMode as String)
    }

    private func post(_ key: CGKeyCode, _ flags: CGEventFlags = []) {
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: down) else { continue }
            e.flags = flags
            e.setIntegerValueField(.eventSourceUserData, value: marker)
            e.post(tap: .cgSessionEventTap)
        }
    }

    private func copyThenSend(_ app: NSRunningApplication, key: CGKeyCode) {
        let pb = NSPasteboard.general
        let saved = pb.pasteboardItems?.map { item in
            item.types.compactMap { t in item.data(forType: t).map { (t, $0) } }
        } ?? []
        let before = pb.changeCount
        post(0, .maskCommand)   // ⌘A
        post(8, .maskCommand)   // ⌘C

        func finish(_ tries: Int) {
            if pb.changeCount == before && tries > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { finish(tries - 1) }
                return
            }
            let text = pb.changeCount != before ? (pb.string(forType: .string) ?? "") : ""
            post(key)   // 放行回车，消息照常发出
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                if pb.changeCount != before {   // 剪贴板还原
                    pb.clearContents()
                    pb.writeObjects(saved.map { pairs in
                        let it = NSPasteboardItem()
                        for (t, d) in pairs { it.setData(d, forType: t) }
                        return it
                    })
                }
                self.busy = false
            }
            let hits = Swear.find(text)
            debugLog("copy app=\(app.localizedName ?? "?") len=\(text.count) hits=\(hits.count)")
            guard !hits.isEmpty else { return }
            var title = ""
            if let w = AX.attr(AXUIElementCreateApplication(app.processIdentifier), kAXFocusedWindowAttribute) {
                title = (AX.attr(w as! AXUIElement, kAXTitleAttribute) as? String) ?? ""
            }
            onHit?(Snapshot(element: nil, text: text, pid: app.processIdentifier,
                            app: app.localizedName ?? "微信", bundle: app.bundleIdentifier ?? "",
                            window: title), hits)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { finish(5) }
    }

    func onEnter() {
        guard !paused else { return }
        var snap = AX.snapshot()
        if snap == nil || snap!.text.isEmpty,
           let (cached, at) = lastPolled, Date().timeIntervalSince(at) < 3,
           cached.pid == NSWorkspace.shared.frontmostApplication?.processIdentifier {
            snap = cached
        }
        debugLog("enter app=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?") "
                 + "read=\(snap != nil) len=\(snap?.text.count ?? -1) hits=\(snap.map { Swear.find($0.text).count } ?? 0)")
        guard let s = snap else { return }
        let hits = Swear.find(s.text)
        guard !hits.isEmpty else { return }

        // 等一下再看：输入框被清空 = 消息真的发出去了；
        // 没清空 = 输入法上屏 / 换行，不算，避免重复计数
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            let after = s.element.flatMap { AX.text(of: $0) } ?? ""
            let sent = after.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !after.contains(s.text.trimmingCharacters(in: .whitespacesAndNewlines))
            debugLog("  after len=\(after.count) sent=\(sent)")
            guard sent else { return }
            self?.lastPolled = nil
            self?.onHit?(s, hits)
        }
    }
}

let monitor = Monitor()

/// 只记 app 名和长度，不记内容
func debugLog(_ s: String) {
    let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("TMDCounter/debug.log")
    let line = Data("\(Date()) \(s)\n".utf8)
    if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(line); try? h.close() }
    else { try? line.write(to: url) }
}

private func tapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                         refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        monitor.reenable()
    } else if type == .keyDown {
        if !monitor.handleKey(event) { return nil }
    }
    return Unmanaged.passUnretained(event)
}

// MARK: - 统计页面

enum Dashboard {
    static func write(_ store: Store) -> URL {
        let url = store.dir.appendingPathComponent("dashboard.html")
        let json = (try? String(data: JSONEncoder().encode(store.records), encoding: .utf8)) ?? "[]"
        let html = template.replacingOccurrences(of: "__DATA__",
                                                 with: json.replacingOccurrences(of: "</", with: "<\\/"))
        try? html.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    static let template = #"""
<!doctype html><html lang="zh"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>他妈的记录器</title>
<style>
:root{--bg:#faf8f5;--card:#fff;--ink:#1d1b19;--mute:#8a847d;--line:#ece7e1;--acc:#e5484d;--acc2:#f5a524;--acc3:#7c66dc;--bar:#e5484d}
@media (prefers-color-scheme:dark){:root{--bg:#161514;--card:#201f1d;--ink:#f1eee9;--mute:#9a948c;--line:#2e2c29}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--ink);font:15px/1.5 -apple-system,"PingFang SC",sans-serif}
.wrap{max-width:960px;margin:0 auto;padding:28px 16px 60px}
h1{font-size:26px;margin:0 0 4px}.sub{color:var(--mute);margin-bottom:20px}
.tabs{display:flex;gap:6px;margin-bottom:18px}.tabs button{border:1px solid var(--line);background:var(--card);color:var(--ink);padding:6px 14px;border-radius:999px;cursor:pointer;font:inherit}
.tabs button.on{background:var(--ink);color:var(--bg);border-color:var(--ink)}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(200px,1fr));gap:12px;margin-bottom:12px}
.card{background:var(--card);border:1px solid var(--line);border-radius:14px;padding:16px}
.card h3{margin:0 0 10px;font-size:13px;color:var(--mute);font-weight:500}
.big{font-size:56px;font-weight:700;line-height:1;color:var(--acc)}
.row{display:flex;align-items:center;gap:8px;margin:6px 0}.row .k{width:84px;flex:none;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.row .b{height:10px;border-radius:5px;background:var(--acc)}.row .v{color:var(--mute);font-variant-numeric:tabular-nums}
.hours{display:flex;align-items:flex-end;gap:3px;height:120px}.hours div{flex:1;background:var(--bar);border-radius:3px 3px 0 0;min-height:2px;opacity:.85}
.hl{display:flex;justify-content:space-between;color:var(--mute);font-size:11px;margin-top:4px}
.q{border-top:1px solid var(--line);padding:10px 0}.q:first-child{border-top:0}.q .m{color:var(--mute);font-size:12px}
.q mark{background:none;color:var(--acc);font-weight:700}
input{width:100%;padding:8px 12px;border:1px solid var(--line);border-radius:8px;background:var(--bg);color:var(--ink);font:inherit;margin-bottom:8px}
.empty{color:var(--mute);padding:30px;text-align:center}
</style></head><body><div class="wrap">
<h1>🤬 他妈的记录器</h1><div class="sub" id="sub"></div>
<div class="tabs" id="tabs"></div>
<div class="grid">
 <div class="card"><h3>总次数</h3><div class="big" id="total"></div></div>
 <div class="card"><h3>按词</h3><div id="byWord"></div></div>
 <div class="card"><h3>按场景</h3><div id="byScene"></div></div>
</div>
<div class="grid">
 <div class="card"><h3>按 App</h3><div id="byApp"></div></div>
 <div class="card"><h3>按窗口 / 聊天对象</h3><div id="byWin"></div></div>
</div>
<div class="card" style="margin-bottom:12px"><h3>一天中什么时候最暴躁</h3><div class="hours" id="hours"></div><div class="hl"><span>0点</span><span>6点</span><span>12点</span><span>18点</span><span>23点</span></div></div>
<div class="card" id="trendCard" style="margin-bottom:12px"><h3>最近 14 天</h3><div class="hours" id="trend"></div><div class="hl" id="trendL"></div></div>
<div class="card"><h3>语录</h3><input id="search" placeholder="搜索原句 / app"><div id="quotes"></div></div>
</div><script>
const ALL=__DATA__;
const WORDS=[...new Set(ALL.flatMap(r=>r.words))].sort((a,b)=>b.length-a.length);
const mark=t=>WORDS.length?t.replace(new RegExp(WORDS.join("|"),"g"),"<mark>$&</mark>"):t;
const ranges={今天:1,"7 天":7,"30 天":30,全部:0};let cur="今天";
const esc=s=>String(s??"").replace(/[&<>"]/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;"}[c]));
function pick(){const d=ranges[cur];if(!d)return ALL;const s=new Date();s.setHours(0,0,0,0);s.setDate(s.getDate()-(d-1));return ALL.filter(r=>r.ts*1000>=s)}
function bars(el,m,limit=6){const e=Object.entries(m).sort((a,b)=>b[1]-a[1]).slice(0,limit);const mx=Math.max(1,...e.map(x=>x[1]));
 document.getElementById(el).innerHTML=e.length?e.map(([k,v])=>`<div class="row"><span class="k" title="${esc(k)}">${esc(k)}</span><span class="b" style="width:${v/mx*100}%"></span><span class="v">${v}</span></div>`).join(""):'<div class="v" style="color:var(--mute)">暂无</div>'}
function render(){
 document.getElementById("tabs").innerHTML=Object.keys(ranges).map(k=>`<button class="${k==cur?"on":""}" onclick="cur='${k}';render()">${k}</button>`).join("");
 const R=pick(),n=R.reduce((a,r)=>a+r.words.length,0);
 document.getElementById("total").textContent=n;
 document.getElementById("sub").textContent=ALL.length?`从 ${new Date(ALL[0].ts*1000).toLocaleDateString()} 开始记录，共 ${ALL.reduce((a,r)=>a+r.words.length,0)} 次`:"还没有记录，去微信骂一句试试";
 const w={},s={},a={},win={},h=Array(24).fill(0);
 for(const r of R){for(const x of r.words)w[x]=(w[x]||0)+1;const c=r.words.length;s[r.scene]=(s[r.scene]||0)+c;a[r.app]=(a[r.app]||0)+c;
  const t=r.window&&r.window!==r.app?`${r.app} · ${r.window}`:r.app;win[t]=(win[t]||0)+c;h[new Date(r.ts*1000).getHours()]+=c}
 bars("byWord",w);bars("byScene",s);bars("byApp",a);bars("byWin",win,8);
 const mh=Math.max(1,...h);document.getElementById("hours").innerHTML=h.map((v,i)=>`<div style="height:${v/mh*100}%" title="${i}点：${v} 次"></div>`).join("");
 const days=[];for(let i=13;i>=0;i--){const d=new Date();d.setHours(0,0,0,0);d.setDate(d.getDate()-i);days.push(d)}
 const dc=days.map(d=>ALL.filter(r=>{const t=r.ts*1000;return t>=d&&t<+d+864e5}).reduce((a,r)=>a+r.words.length,0));const md=Math.max(1,...dc);
 document.getElementById("trend").innerHTML=dc.map((v,i)=>`<div style="height:${v/md*100}%;background:var(--acc3)" title="${days[i].getMonth()+1}/${days[i].getDate()}：${v} 次"></div>`).join("");
 document.getElementById("trendL").innerHTML=`<span>${days[0].getMonth()+1}/${days[0].getDate()}</span><span>今天</span>`;
 quotes(R)}
function quotes(R){const q=document.getElementById("search").value.trim();
 const L=R.filter(r=>!q||(r.text||"").includes(q)||r.app.includes(q)||(r.window||"").includes(q)).slice().reverse().slice(0,200);
 document.getElementById("quotes").innerHTML=L.length?L.map(r=>`<div class="q"><div>${r.text?mark(esc(r.text)):"<i>（未保存原句）</i>"}</div><div class="m">${new Date(r.ts*1000).toLocaleString()} · ${esc(r.app)}${r.window&&r.window!==r.app?" · "+esc(r.window):""} · ${esc(r.scene)}</div></div>`).join(""):'<div class="empty">这段时间你很文明</div>'}
document.getElementById("search").oninput=()=>quotes(pick());render();
</script></body></html>
"""#
}

// MARK: - 菜单栏

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let store = Store()
    var item: NSStatusItem!
    var permTimer: Timer?
    let defaults = UserDefaults.standard
    var saveText: Bool {
        get { defaults.object(forKey: "saveText") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "saveText") }
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu(); menu.delegate = self; item.menu = menu
        monitor.onHit = { [weak self] s, words in self?.record(s, words) }
        refreshTitle()
        debugLog("launch trusted=\(AXIsProcessTrusted())")

        if !monitor.start() {
            // 首次运行：弹出系统授权框，授权后自动开始
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            AXIsProcessTrustedWithOptions(opts)
            permTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] t in
                if monitor.start() { t.invalidate(); self?.refreshTitle() }
            }
        }
    }

    func record(_ s: Snapshot, _ words: [String]) {
        let scene = Scene.classify(app: s.app, bundle: s.bundle, window: s.window)
        store.append(Record(ts: Date().timeIntervalSince1970, app: s.app, bundle: s.bundle,
                            window: s.window, scene: scene, words: words,
                            text: saveText ? String(s.text.prefix(500)) : nil))
        refreshTitle()
    }

    func refreshTitle() {
        let n = store.today().reduce(0) { $0 + $1.words.count }
        item.button?.title = monitor.running ? (monitor.paused ? "🤐 \(n)" : "🤬 \(n)") : "🤬 ⚠️"
    }

    // 每次打开菜单时现生成
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let today = store.today()
        let total = today.reduce(0) { $0 + $1.words.count }

        if !monitor.running {
            add(menu, "⚠️ 需要“辅助功能”权限，点这里去开启", #selector(openPermission))
            menu.addItem(.separator())
        }
        info(menu, "今天：\(total) 次")
        if total > 0 {
            var w: [String: Int] = [:], sc: [String: Int] = [:]
            for r in today { for x in r.words { w[x, default: 0] += 1 }; sc[r.scene.rawValue, default: 0] += r.words.count }
            info(menu, Swear.summary(w, sep: " · "))
            info(menu, ["聊天", "AI", "其他"].map { "\($0) \(sc[$0] ?? 0)" }.joined(separator: " · "))
            menu.addItem(.separator())
            info(menu, "最近：")
            let f = DateFormatter(); f.dateFormat = "HH:mm"
            for r in today.suffix(5).reversed() {
                let t = r.text.map { $0.count > 28 ? String($0.prefix(28)) + "…" : $0 } ?? r.words.joined(separator: " ")
                info(menu, "  \(f.string(from: r.date)) [\(r.app)] \(t.replacingOccurrences(of: "\n", with: " "))")
            }
        }
        menu.addItem(.separator())
        add(menu, "打开统计页面", #selector(openDashboard), key: "d")
        add(menu, "复制今日战报（发给朋友）", #selector(copyReport), key: "c")
        menu.addItem(.separator())
        add(menu, monitor.paused ? "继续记录" : "暂停记录", #selector(togglePause))
        add(menu, "保存原句", #selector(toggleSaveText)).state = saveText ? .on : .off
        if #available(macOS 13, *) {
            add(menu, "开机自动启动", #selector(toggleLogin)).state =
                SMAppService.mainApp.status == .enabled ? .on : .off
        }
        add(menu, "检测微信（排查用）", #selector(diagnose))
        add(menu, "打开数据文件夹", #selector(openFolder))
        menu.addItem(.separator())
        add(menu, "退出", #selector(NSApplication.terminate(_:)), key: "q")
    }

    @discardableResult
    func add(_ m: NSMenu, _ t: String, _ a: Selector, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: t, action: a, keyEquivalent: key)
        i.target = a == #selector(NSApplication.terminate(_:)) ? NSApp : self
        m.addItem(i); return i
    }

    func info(_ m: NSMenu, _ t: String) {
        let i = NSMenuItem(title: t, action: nil, keyEquivalent: ""); i.isEnabled = false; m.addItem(i)
    }

    @objc func openPermission() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(opts)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc func openDashboard() { NSWorkspace.shared.open(Dashboard.write(store)) }
    @objc func openFolder() { NSWorkspace.shared.open(store.dir) }
    @objc func togglePause() { monitor.paused.toggle(); refreshTitle() }
    @objc func toggleSaveText() { saveText.toggle() }

    @available(macOS 13, *)
    @objc func toggleLogin() {
        let s = SMAppService.mainApp
        do { if s.status == .enabled { try s.unregister() } else { try s.register() } }
        catch { alert("设置失败", "请先把 app 拖进“应用程序”文件夹再试。\n\(error.localizedDescription)") }
    }

    @objc func copyReport() {
        let today = store.today()
        let total = today.reduce(0) { $0 + $1.words.count }
        var w: [String: Int] = [:], sc: [String: Int] = [:], hours = [Int](repeating: 0, count: 24)
        for r in today {
            for x in r.words { w[x, default: 0] += 1 }
            sc[r.scene.rawValue, default: 0] += r.words.count
            hours[Calendar.current.component(.hour, from: r.date)] += r.words.count
        }
        var lines = ["🤬 今日脏话战报", "共 \(total) 次"]
        if total > 0 {
            lines.append(Swear.summary(w, sep: " / "))
            lines.append("微信等聊天 \(sc["聊天"] ?? 0) 次，骂 AI \(sc["AI"] ?? 0) 次")
            if let peak = hours.indices.max(by: { hours[$0] < hours[$1] }) { lines.append("最暴躁时段：\(peak) 点") }
        } else {
            lines.append("今天很文明 😇")
        }
        lines.append("—— 他妈的记录器")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }

    @objc func diagnose() {
        // 直接检测微信，不靠用户手速切窗口
        let wechat = NSRunningApplication.runningApplications(withBundleIdentifier: "com.tencent.xinWeChat").first
        if wechat == nil { alert("没找到微信", "请先打开微信再检测。"); return }
        wechat?.activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            let app = wechat
            if let app {
                AX.wake(app)
                try? AX.dump(app).write(to: self.store.dir.appendingPathComponent("axdump.txt"),
                                        atomically: true, encoding: .utf8)
            }
            let msg: String
            if !AXIsProcessTrusted() {
                msg = "还没有辅助功能权限。"
            } else if let s = AX.snapshot() {
                msg = "App：\(s.app)\n窗口：\(s.window.isEmpty ? "（无标题）" : s.window)\n场景：\(Scene.classify(app: s.app, bundle: s.bundle, window: s.window).rawValue)\n读到的内容：\(s.text.isEmpty ? "（空）" : s.text)\n\n✅ 能读到就说明这个 app 可以统计。"
            } else {
                msg = Monitor.copyApps.contains(app?.bundleIdentifier ?? "")
                    ? "App：\(app?.localizedName ?? "?")\n这个 app 读不到输入框，已改用“发送前自动复制”的方式统计。\n直接发一条“他妈的”试试，菜单栏数字会 +1。"
                    : "App：\(app?.localizedName ?? "?")\n❌ 读不到输入框内容，这个 app 暂时统计不了。"
            }
            NSApp.activate(ignoringOtherApps: true)
            self.alert("检测结果", msg)
        }
    }

    func alert(_ title: String, _ text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert(); a.messageText = title; a.informativeText = text; a.runModal()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
