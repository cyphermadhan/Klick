# Retro / Learnings

## [2026-05-28] — iOS 26 crashes URLSession callback APIs on @MainActor

**What happened:** App crashed with `EXC_BREAKPOINT` (code=1) twice — first when creating `URLSession(configuration: .default)` inside a `DispatchQueue.async` closure in `InternetTransport.connect()`, then when calling `URLSession.shared.dataTask(with:)` from a `@MainActor`-isolated method in `PushManager`.

**Root cause:** iOS 26 (Xcode 26.3 SDK) added strict thread/actor assertions to URLSession APIs. Creating a URLSession inside a background dispatch queue, or calling the old callback-based `dataTask(with:completionHandler:)` from `@MainActor` context, now triggers a runtime breakpoint that didn't exist in iOS 18.

**Fix / resolution:**
1. `InternetTransport`: moved `URLSession(configuration: .default)` to `init()` (runs on main thread at construction time). The session is stored as a `let` property and reused.
2. `PushManager`: replaced `URLSession.shared.dataTask(with:) { ... }.resume()` with `Task.detached { try await URLSession.shared.data(for: request) }` — runs the network call off the main actor entirely.

**Rule going forward:** On iOS 26+, never create URLSession instances inside `DispatchQueue.async` blocks. Never use `dataTask(with:completionHandler:)` from `@MainActor`. Always use `async/await` URLSession APIs (`data(for:)`, `webSocketTask(with:)`) and run them in `Task.detached` if called from actor-isolated code.
