# Swift Memory Safety

ARC, retain cycles, and lifetime management patterns for this project.

## ARC Fundamentals

Swift uses Automatic Reference Counting (ARC). Key rules:

- **Strong references** (default): Increment reference count, keep object alive
- **Weak references** (`weak`): Don't increment count, become `nil` when deallocated
- **Unowned references** (`unowned`): Don't increment count, crash if accessed after deallocation
- Value types (`struct`, `enum`) are not reference-counted — they're copied

## Common Retain Cycle Patterns

### Closures Capturing `self`

The most common source of retain cycles in this codebase:

```swift
// WRONG: Strong reference cycle — closure captures self strongly
volumeForwardQueue.async {
    self.forwardVolumeToOutput(newVolume, outputID: outputID)
}

// CORRECT: Break the cycle with [weak self]
volumeForwardQueue.async { [weak self] in
    self?.forwardVolumeToOutput(newVolume, outputID: outputID)
}
```

Rules:
- Always use `[weak self]` in GCD closures
- Always use `[weak self]` in delegate callbacks
- Use `[unowned self]` only when the closure's lifetime is strictly bounded by `self`'s lifetime (rare)

### Delegates

Delegate properties must be `weak` to prevent parent-child cycles:

```swift
// Protocol conformance
protocol SomeDelegateing: AnyObject {
    func didReceiveUpdate(_ value: Float)
}

// Weak delegate reference
weak var delegate: SomeDelegateing?
```

Rules:
- Delegate protocols should conform to `AnyObject` (enables `weak`)
- Always declare delegate properties as `weak`
- This codebase uses protocols with `-ing` suffix for service protocols (`Enumerating`, `VolumeControlling`, `SampleRateObserving`)

### Coordinator Pattern

Coordinators in this project are `@MainActor` and manage lifecycle of their dependencies:

```swift
@MainActor final class AudioRoutingCoordinator {
    private let deviceProvider: DeviceProviding    // Protocol reference — owned
    private var volumeManager: VolumeControlling?   // Created lazily, owned
}
```

No retain cycle here because:
- Coordinator owns its dependencies (strong references)
- Dependencies don't hold references back to the coordinator
- If bidirectional references exist, one must be `weak`

## View Model Lifetime

View models use `unowned` store references:

```swift
@Observable final class RoutingViewModel {
    private unowned let store: EqualiserStore
}
```

This is safe because:
- View models are created by views on the main actor
- Store outlives all view models
- View models don't retain the store

**When to use `unowned` vs `weak`:**
- Use `unowned` when: The owner always outlives the reference, and you want zero-overhead access
- Use `weak` when: The referenced object might be deallocated independently, and you need to handle `nil`

## GCD and Lifetime

### Dispatching to Main Queue

```swift
DispatchQueue.main.async { [weak self] in
    self?.updateUI()
}
```

- Always use `[weak self]` when dispatching from a background context
- The object might be deallocated between dispatch and execution

### Dispatching to Serial Queue

```swift
private let volumeForwardQueue = DispatchQueue(label: "com.equaliser.volume")

volumeForwardQueue.async { [weak self] in
    self?.forwardVolumeToOutput(newVolume, outputID: outputID)
}
```

- Serial queues ensure ordering but don't prevent retain cycles
- Use `[weak self]` for any closure that might outlive the current scope

## NotificationCenter Observers

Block-based observers (`addObserver(forName:object:queue:using:)`) are retained by
`NotificationCenter` itself until explicitly removed — `[weak self]` inside the block does
**not** protect against this, because the leak is the registration itself, not a capture cycle.

```swift
// WRONG: token discarded — this observer can never be removed, and if this
// call site re-runs (e.g. inside `updateNSView`, a `body` re-evaluation, or
// any other repeatable code path) each run adds a permanent, unremovable
// duplicate.
NotificationCenter.default.addObserver(forName: .someEvent, object: nil, queue: .main) { _ in
    self?.handleEvent()
}

// CORRECT: store the token, remove it when the observer's owner goes away
private var eventToken: NSObjectProtocol?

eventToken = NotificationCenter.default.addObserver(forName: .someEvent, object: nil, queue: .main) { _ in
    self?.handleEvent()
}

deinit {
    if let eventToken { NotificationCenter.default.removeObserver(eventToken) }
}
```

Rules:
- Always capture the return value of `addObserver(forName:object:queue:using:)`.
- Remove it in `deinit` (classes) or `.onDisappear` (SwiftUI views whose lifetime matches the
  window/scene).
- Never call `addObserver` from a function that can run more than once per logical "session"
  (e.g. `updateNSView`, a `body` computed property, or any `makeNSView` that could be invoked
  again) without first removing any previously-stored token — otherwise each re-run
  permanently leaks another observer.
- Prefer the selector-based `addObserver(self, selector:...)` + `removeObserver(self)` form for
  anything registered exactly once for an object's whole lifetime (see `EqualiserStore.init`/
  `deinit`); reserve the block-based form for cases that genuinely need per-registration tokens.
- See `WindowAccessor.swift` for the pattern that ensures a callback fires only once per actual
  state change, so call sites registering observers inside it don't need to guard against
  re-entrancy themselves.

## Swift/ObjC Interop

This project uses CoreAudio (C API) and AVFoundation (ObjC framework):

### AudioObject Property Callbacks

```swift
var propertyAddress = AudioObjectPropertyAddress(...)
AudioObjectAddPropertyDataBlock(deviceID, &propertyAddress, 0, nil) { [weak self] _, _ in
    DispatchQueue.main.async {
        self?.handleDeviceChange()
    }
}
```

Rules:
- CoreAudio callbacks run on arbitrary threads — never assume main thread
- Always dispatch to main queue for UI updates
- Use `[weak self]` in all CoreAudio callbacks
- AudioObject property listeners are `nonisolated` — they don't belong to any actor

### Bridging Types

- `AudioDeviceID` is a `UInt32` typedef — passed by value, no lifetime issues
- `AudioObjectID` is a `UInt32` typedef — same
- `CFString` bridging: Use `as String` for conversions, ensure lifetime with explicit `Unmanaged<CFString>` when needed

## Audio Thread Memory Rules

The audio render thread has additional constraints:

- **No allocation**: ARC can trigger allocation — avoid any operation that might allocate
- **No reference counting transitions**: Avoid passing objects across the audio thread boundary that would trigger retain/release
- **Use `nonisolated(unsafe)`**: For properties accessed from audio thread, bypass Swift 6 checking but document the safety proof
- **Pre-allocate everything**: All buffers, setups, and state must be allocated at init time, never during render callbacks

```swift
// SAFE: Pre-allocated at init, only read during render
nonisolated(unsafe) var callbackContext: RenderCallbackContext?

// UNSAFE: Could allocate during render
var processedSamples: [Float] = []  // Array might reallocate!
```

## Testing and Memory

- Use `@testable import Equaliser` for access to internal types
- Test `deinit` is called by using `addTeardownBlock` or weak reference checks
- Leaks in tests usually indicate missing `[weak self]` in closures