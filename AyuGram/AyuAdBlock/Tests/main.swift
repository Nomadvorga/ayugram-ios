// Host check of the filter list converter. Run from the repository root:
// swiftc -warnings-as-errors -o /tmp/ayu-adblock-tests AyuGram/AyuAdBlock/Sources/AyuAdBlockConverter.swift AyuGram/AyuAdBlock/Tests/main.swift && /tmp/ayu-adblock-tests
// With paths of filter lists as arguments it also converts them and has WebKit compile the result:
// /tmp/ayu-adblock-tests /tmp/ayu/lists/easylist.txt ...

import Foundation
import WebKit

var passed = 0
var failed = 0
func check(_ label: String, _ expected: String, _ actual: String) {
    if expected == actual {
        passed += 1
    } else {
        failed += 1
        print("FAILED \(label): expected \(expected), got \(actual)")
    }
}

func describe(_ rule: AyuAdBlockRule?) -> String {
    guard let rule else {
        return "nil"
    }
    var parts = [rule.urlFilter]
    if rule.isCaseSensitive { parts.append("case") }
    if !rule.ifDomain.isEmpty { parts.append("if=" + rule.ifDomain.joined(separator: ",")) }
    if !rule.unlessDomain.isEmpty { parts.append("unless=" + rule.unlessDomain.joined(separator: ",")) }
    if !rule.resourceTypes.isEmpty { parts.append(rule.resourceTypes == AyuAdBlockConverter.subresourceTypes ? "types=sub" : "types=" + rule.resourceTypes.joined(separator: ",")) }
    if !rule.loadTypes.isEmpty { parts.append("load=" + rule.loadTypes.joined(separator: ",")) }
    switch rule.action {
    case .block: parts.append("block")
    case .ignorePreviousRules: parts.append("allow")
    case let .hide(selector): parts.append("hide " + selector)
    }
    return parts.joined(separator: " ")
}
func network(_ line: String) -> String {
    return describe(AyuAdBlockConverter.network(line))
}

let host = "^[^:]+:(//)?([^/]+\\.)?"
let sep = "[^a-zA-Z0-9_.%-]"
check("host anchor with a separator at the end", "\(host)ads\\.example\\.com(\(sep).*)?$ types=sub block", network("||ads.example.com^"))
check("plain substring", "\\/banner\\/ads\\. types=sub block", network("/banner/ads."))
check("wildcards and separators inside", "\(host)example\\.com\(sep)ad.*\\.js types=sub block", network("||example.com^ad**.js*"))
check("start and end anchors", "^http:\\/\\/ads\\.$ types=sub block", network("|http://ads.|"))
check("lower case unless the filter matches case", "\\/adbanner types=sub block | \\/AdBanner case types=sub block", "\(network("/AdBanner")) | \(network("/AdBanner$match-case"))")
check("third party covers frames too", "\(host)tracker\\.io(\(sep).*)?$ load=third-party block", network("||tracker.io^$third-party"))
check("first party", "\\/stats\\.js types=sub load=first-party block", network("/stats.js$~third-party"))
check("resource types", "\\/pixel types=image,script block | \\/api\\/track types=raw,fetch load=third-party block", "\(network("/pixel$image,script")) | \(network("/api/track$xhr,3p"))")
check("excluded types", "\\/adframe types=style-sheet,script,font,raw,svg-document,media,ping,fetch,websocket,other block", network("/adframe$~image"))
check("a frame is another site's document", "\(host)adhost\\.net(\(sep).*)?$ types=document load=third-party block | nil", "\(network("||adhost.net^$subdocument")) | \(network("||adhost.net^$subdocument,~third-party"))")
check("frame among other types on the same site keeps the others", "\\/promo types=script load=first-party block", network("/promo$script,subdocument,1p"))
check("domains", "\\/ad\\.js if=*news.com,*blog.org types=sub block | \\/ad\\.js unless=*shop.com types=sub block | nil", "\(network("/ad.js$domain=news.com|blog.org")) | \(network("/ad.js$domain=~shop.com")) | \(network("/ad.js$domain=a.com|~b.a.com"))")
check("a short pattern needs a site", "nil | .* if=*site.com types=image block | ad if=*site.com types=sub block", "\(network("ad")) | \(network("*$image,domain=site.com")) | \(network("ad$domain=site.com"))")
check("exceptions", "\(host)cdn\\.example\\.com\\/player types=sub allow | .* if=*example.com allow", "\(network("@@||cdn.example.com/player")) | \(network("@@||example.com^$document"))")
check("blocking a whole page is not done", "nil nil", "\(network("||malware.example^$document")) \(network("@@/ads$document"))")
check("another engine's work", "nil nil nil nil nil nil nil", ["||a.com/x.js$redirect=noop.js", "/track?$removeparam=utm", "||a.com^$csp=script-src 'none'", "/^https?:\\/\\/ads\\d+\\./", "||a.com^$popup", "@@||a.com^$generichide", "||реклама.рф^"].map(network).joined(separator: " "))
check("a dollar inside the address", "\\/ad\\$banner\\/x types=sub block", network("/ad$banner/x"))
check("entity domains refused", "nil", network("/ad.js$domain=google.*"))

func cosmetic(_ line: String) -> String {
    switch AyuAdBlockConverter.cosmetic(line) {
    case nil: return "nil"
    case .unsupported?: return "unsupported"
    case let .generic(selector)?: return "generic " + selector
    case let .exception(domains, selector)?: return "exception \(domains.joined(separator: ",")) \(selector)"
    case let .rule(rule)?: return describe(rule)
    }
}
check("generic selector", "generic .ad-banner", cosmetic("##.ad-banner"))
check("site selectors", ".* if=*example.com,*sub.test.org hide #ad > div[class^=\"promo\"] | .* unless=*example.com hide .sponsored", "\(cosmetic("example.com,sub.test.org###ad > div[class^=\"promo\"]")) | \(cosmetic("~example.com##.sponsored"))")
check("exception", "exception example.com .ad-banner", cosmetic("example.com#@#.ad-banner"))
check("not expressible", "unsupported unsupported unsupported unsupported unsupported unsupported unsupported", ["example.com##+js(aopr, ads)", "example.com#?#div:has-text(Ad)", "##div:has(> .ad)", "example.*##.ad", "a.com,~b.a.com##.ad", "example.com#$#body { overflow: auto !important; }", "##div[class=\"a]"].map(cosmetic).joined(separator: " "))
check("a network filter with a hash is not element hiding", "nil nil", "\(cosmetic("/ads/#banner/x")) \(cosmetic("||example.com/page#ad"))")

let converted = AyuAdBlockConverter.convert(lists: ["""
[Adblock Plus 2.0]
! Title: test
##.ad
##.banner
##.promo
||ads.example.com^
||ads.example.com^
/track.js$third-party
@@||good.example.com^
news.com##.sticky
news.com#@#.banner
||x.com^$redirect=1x1.gif
""", "##.ad\n##.second-list\n||ads.example.com^\n"])
check("lists converted: counts", "3 2 1 1", "\(converted.hiding.count) \(converted.blocking.count) \(converted.exceptions.count) \(converted.skipped)")
check("an excepted selector keeps off the site, the others share a rule", ".* unless=*news.com hide .banner | .* hide .ad, .promo, .second-list | .* if=*news.com hide .sticky", converted.hiding.map(describe).joined(separator: " | "))
let lists = AyuAdBlockConverter.ruleLists(converted, limit: 4)
check("every rule list ends with the exceptions", "4 3 | true", "\(lists.map { "\($0.count)" }.joined(separator: " ")) | \(lists.allSatisfy { $0.last?.action == .ignorePreviousRules })")
check("json", #"[{"action":{"type":"block"},"trigger":{"load-type":["third-party"],"url-filter":"\\/track\\.js"}}]"#, { () -> String in
    let data = try! JSONSerialization.data(withJSONObject: [converted.blocking[1].json], options: [.sortedKeys, .withoutEscapingSlashes])
    return String(decoding: data, as: UTF8.self)
}())

let paths = CommandLine.arguments.dropFirst()
if !paths.isEmpty {
    let texts = paths.compactMap { try? String(contentsOfFile: $0, encoding: .utf8) }
    let start = Date()
    let rules = AyuAdBlockConverter.convert(lists: texts)
    print("converted \(texts.count) lists in \(String(format: "%.1f", Date().timeIntervalSince(start))) s: \(rules.hiding.count) hiding, \(rules.blocking.count) blocking, \(rules.exceptions.count) exceptions, \(rules.skipped) skipped")
    let ruleLists = AyuAdBlockConverter.ruleLists(rules)
    var index = 0
    func compileNext() {
        guard index < ruleLists.count else {
            print("\(passed) passed, \(failed) failed")
            exit(failed == 0 ? 0 : 1)
        }
        let json = AyuAdBlockConverter.json(ruleLists[index])
        let started = Date()
        let number = index
        WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "ayu-adblock-test-\(number)", encodedContentRuleList: json) { list, error in
            print("list \(number): \(ruleLists[number].count) rules, \(json.utf8.count / 1024) KB, \(list != nil ? "compiled" : "FAILED \(error.map { "\($0)" } ?? "")") in \(String(format: "%.1f", Date().timeIntervalSince(started))) s")
            WKContentRuleListStore.default().removeContentRuleList(forIdentifier: "ayu-adblock-test-\(number)") { _ in
                index += 1
                compileNext()
            }
        }
    }
    compileNext()
    RunLoop.main.run()
}

print("\(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
