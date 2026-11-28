# Visible message image export helper

The helper is internal to TelegramUI, compiled by the existing
`AyuGram/SGTelegramUIExtensions` source filegroup. No BUILD change is required.

```swift
enum ExteraMessageImageExport {
    struct Output {
        let image: UIImage
        let pngData: Data
    }

    static func capture(
        node: ChatMessageItemView,
        message: EngineRawMessage,
        allowExport: Bool,
        backgroundColor: UIColor
    ) throws -> Output
}
```

`CaptureError: Swift.Error` cases are `notOnMainThread`, `exportNotAllowed`,
`messageMismatch`, `groupedMessage`, `protectedContent`, `unsupportedContent`,
`sourceUnavailable`, `sourceNotVisible`, `invalidGeometry`, `imageTooLarge`,
`renderingFailed`, and `encodingFailed`.

## Caller integration

Call on the main thread, while the row's message or its extracted context preview is
attached and fully visible. `allowExport` must represent current chat-level permission,
including both ordinary and own-content copy protection; the helper separately validates
the supplied and currently bound messages. Pass a suitable opaque chat background color
(the helper forces alpha to one). The return values are an image and its PNG encoding;
the helper does not write files, touch the pasteboard, save to Photos, or present UI.

Resolve the actual visible `ChatMessageItemView`; do not create or lay out an offscreen
copy. `getMessageContextSourceNode(stableId:)` supplies the content tree and content rect.
Context previews can reparent the content tree, so capture uses its actual attached view,
not the row wrapper or an ancestor screenshot. A preview in another window is rejected.

Both a `.group` row and any message carrying a grouping key are rejected. Additional
admin-log content is also rejected because that tree can contain previous messages.
Secret-chat peer and secret-message namespaces, copy protection, secret/view-once media,
secret media IDs, paid media, and expired media are rejected. Geometry must be finite,
positive, inside the content view, and fully inside every clipping ancestor and the window.
There is no partial-crop fallback, so a tall partially visible message must be scrolled to
fit before export (and cannot be exported through this helper if it cannot fit onscreen).

The renderer is explicitly opaque, standard range, and at the screen scale capped at 3.
The rounded-up output and source-surface sizes are checked against 16,000,000 pixels
before rendering; the actual CGImage dimensions are checked again before PNG encoding.
Only the isolated message view is drawn, clipped to `contentRect`. No history/window
screenshot can capture an adjacent protected row. A false `drawHierarchy` result throws;
there is no `layer.render` fallback that could silently omit UIKit content.

## Expected visual cases (not yet verified)

- Incoming and outgoing text/caption/photo messages in light and dark themes: output
  contains precisely the context-source crop, with upright text, correct emoji, and the
  bubble's visible decorations. No avatar/neighbor outside that rect enters the image.
- CoreList and ListView rotated histories: output is upright and has the same crop and
  resolution. The history wrapper's pi rotation must not mirror or invert the exported image.
- Bubble-free messages and extracted context previews: source typography and layout stay
  intact; corner/background areas are filled by the caller's opaque color, without black
  transparency, duplicate content, or clipped text.
- 1x/2x/3x sources and fractional crop sizes: sharp text, no extra edge from a neighboring
  row, no output above the pixel cap, and PNG dimensions matching the returned image.
- Protected neighbors above/below: neither appears in the exported crop. Album rows,
  stale/reused nodes, detached rows, hidden ancestors, partial viewport clipping, secret
  chats, view-once/secret media, paid media, and expired media return errors with no output.
- Video, animated stickers, widgets, and other live surfaces need device verification:
  UIKit controls whether those surfaces appear in `drawHierarchy`. This helper does not
  promise original-media extraction or reconstruct a video frame when UIKit cannot draw it.

The Windows environment has no Swift/Xcode or iOS simulator. Source and whitespace checks
are feasible here; no compilation, rendering, PNG appearance, or animation verification is
claimed. On a Mac, build the full target using the root guide and evaluate exported PNGs
against recorded, labelled simulator frames as required by AGENTS.md.
