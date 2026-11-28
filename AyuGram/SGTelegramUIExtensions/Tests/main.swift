// Host check of the reverse image search core. Run from the repository root:
// swiftc -warnings-as-errors -o /tmp/ayu-imagesearch-tests AyuGram/SGTelegramUIExtensions/Sources/AyuReverseImageSearchCore.swift AyuGram/SGTelegramUIExtensions/Tests/main.swift && /tmp/ayu-imagesearch-tests [live]
// "live" uploads a small generated picture to the service.

import Foundation
import CoreGraphics
import ImageIO

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

check("upload address", "https://yandex.com/images/touch/search?rpt=imageview&format=json&request=%7B%22blocks%22%3A%5B%7B%22block%22%3A%22cbir-uploader__get-cbir-id%22%7D%5D%7D", AyuReverseImageSearch.uploadURL)
let request = AyuReverseImageSearch.uploadRequest(jpeg: Data([0xff, 0xd8, 0xff, 0xd9]), userAgent: "UA", boundary: "B")
check("upload headers", "POST multipart/form-data; boundary=B application/json XMLHttpRequest gdpr=0 UA", [request.httpMethod ?? "", request.value(forHTTPHeaderField: "Content-Type") ?? "", request.value(forHTTPHeaderField: "Accept") ?? "", request.value(forHTTPHeaderField: "X-Requested-With") ?? "", request.value(forHTTPHeaderField: "Cookie") ?? "", request.value(forHTTPHeaderField: "User-Agent") ?? ""].joined(separator: " "))
let body = request.httpBody ?? Data()
let bodyHead = Data("--B\r\nContent-Disposition: form-data; name=\"upfile\"; filename=\"image.jpg\"\r\nContent-Type: image/jpeg\r\n\r\n".utf8)
check("upload body", "true true 4", "\(body.starts(with: bodyHead)) \(body.suffix(9) == Data("\r\n--B--\r\n".utf8)) \(body.count - bodyHead.count - 9)")

let answer = Data(#"{"blocks":[{"name":{"block":"cbir-uploader__get-cbir-id"},"params":{"url":"...","cbirId":"1234/abc_DEF-5","originalImageUrl":"https://avatars.mds.yandex.net/get-images-cbir/1234/abc_DEF-5/orig"}}]}"#.utf8)
func url(_ provider: AyuReverseImageSearch.Provider) -> String {
    return AyuReverseImageSearch.searchURL(provider: provider, uploadResponse: answer, uploadHost: "yandex.com.tr") ?? "nil"
}
let image = "https%3A%2F%2Favatars.mds.yandex.net%2Fget-images-cbir%2F1234%2Fabc_DEF-5%2Forig"
check("yandex", "https://yandex.com.tr/images/search?rpt=imageview&cbir_id=1234%2Fabc_DEF-5&url=\(image)", url(.yandex))
check("google", "https://lens.google.com/uploadbyurl?url=\(image)", url(.google))
check("bing", "https://www.bing.com/images/search?view=detailv2&iss=sbi&form=SBIVSP&sbisrc=UrlPaste&q=imgurl:\(image)", url(.bing))
check("tineye", "https://tineye.com/search?url=\(image)", url(.tineye))
check("answers without an address", "nil nil nil", [#"{"blocks":[{"params":{"cbirId":"1"}}]}"#, #"{"blocks":[]}"#, "<html>captcha</html>"].map { AyuReverseImageSearch.searchURL(provider: .google, uploadResponse: Data($0.utf8), uploadHost: "yandex.com") ?? "nil" }.joined(separator: " "))

if CommandLine.arguments.contains("live") {
    let size = 200
    let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    for index in 0 ..< 20 {
        context.setFillColor(CGColor(red: CGFloat(index) / 20.0, green: 0.4, blue: 1.0 - CGFloat(index) / 20.0, alpha: 1.0))
        context.fill(CGRect(x: index * 10, y: 0, width: 10, height: size))
    }
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    CGImageDestinationFinalize(destination)
    let semaphore = DispatchSemaphore(value: 0)
    let upload = AyuReverseImageSearch.uploadRequest(jpeg: data as Data, userAgent: "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148")
    URLSession(configuration: .ephemeral).dataTask(with: upload) { data, response, error in
        let host = response?.url?.host ?? "yandex.com"
        print("live: HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0) from \(host), \(data.flatMap { AyuReverseImageSearch.searchURL(provider: .google, uploadResponse: $0, uploadHost: host) } ?? "no address (\(error?.localizedDescription ?? String(decoding: (data ?? Data()).prefix(160), as: UTF8.self)))")")
        semaphore.signal()
    }.resume()
    _ = semaphore.wait(timeout: .now() + 40.0)
}

print("\(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
