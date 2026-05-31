# Retro / Learnings

## [2026-05-31] — iOS 26 ScrollView + TextField causes horizontal drift

**What happened:** Settings page (the only page with TextFields inside a ScrollView) could be dragged in all directions — horizontally, diagonally — not just vertically. Every other page without TextFields worked fine.

**Root cause:** iOS 26 changed how TextField's internal DragGesture (used for text selection and cursor positioning) interacts with parent ScrollViews. The gesture "leaks" into the ScrollView's content offset, causing horizontal movement even when the ScrollView is explicitly set to `.vertical`. Pages without TextFields are unaffected because there's no internal DragGesture to leak.

**What didn't work:**
- `ScrollView(.vertical)` — still moves
- Removing NavigationStack — still moves
- `.fullScreenCover` instead of `.sheet` — still moves
- `UIScrollView.appearance().alwaysBounceHorizontal = false` — overridden by SwiftUI
- `.fixedSize(horizontal: false, vertical: false)` — no effect
- `.navigationDestination` push instead of sheet — still moves

**Fix / resolution:** Wrap the ScrollView in a `GeometryReader` and pin the content VStack to `.frame(width: geo.size.width)`. This locks the content to the exact available width — the TextField's leaked gesture has zero horizontal room to move anything.

```swift
GeometryReader { geo in
    ScrollView(.vertical, showsIndicators: false) {
        VStack(spacing: 16) { ... }
            .frame(width: geo.size.width)
    }
}
```

**Rule going forward:** On iOS 26+, any ScrollView containing TextFields must have its content width pinned via `GeometryReader + .frame(width: geo.size.width)`. The bare `ScrollView(.vertical)` axis constraint alone is not sufficient when TextFields are present.

---

## [2026-05-28] — iOS 26 crashes URLSession callback APIs on @MainActor

**What happened:** App crashed with `EXC_BREAKPOINT` (code=1) twice — first when creating `URLSession(configuration: .default)` inside a `DispatchQueue.async` closure in `InternetTransport.connect()`, then when calling `URLSession.shared.dataTask(with:)` from a `@MainActor`-isolated method in `PushManager`.

**Root cause:** iOS 26 (Xcode 26.3 SDK) added strict thread/actor assertions to URLSession APIs. Creating a URLSession inside a background dispatch queue, or calling the old callback-based `dataTask(with:completionHandler:)` from `@MainActor` context, now triggers a runtime breakpoint that didn't exist in iOS 18.

**Fix / resolution:**
1. `InternetTransport`: moved `URLSession(configuration: .default)` to `init()` (runs on main thread at construction time). The session is stored as a `let` property and reused.
2. `PushManager`: replaced `URLSession.shared.dataTask(with:) { ... }.resume()` with `Task.detached { try await URLSession.shared.data(for: request) }` — runs the network call off the main actor entirely.

**Rule going forward:** On iOS 26+, never create URLSession instances inside `DispatchQueue.async` blocks. Never use `dataTask(with:completionHandler:)` from `@MainActor`. Always use `async/await` URLSession APIs (`data(for:)`, `webSocketTask(with:)`) and run them in `Task.detached` if called from actor-isolated code.
