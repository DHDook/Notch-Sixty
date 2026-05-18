# Equaliser

A system-wide audio equalizer for macOS, built with Swift 6 and SwiftUI.

## Project Overview

Equaliser is a macOS menu bar application that captures system audio via a custom virtual audio driver, processes it through a parametric EQ engine (up to 64 bands per channel), and routes the processed signal to the user's selected output device.

## Tech Stack

- **Language:** Swift 6 (strict concurrency)
- **UI Framework:** SwiftUI
- **Audio:** CoreAudio / HAL, AVFoundation, vDSP / Accelerate
- **Build System:** Swift Package Manager (SPM)
- **Package Manager:** SPM via `Package.swift`
- **Dev Environment:** Nix (flake.nix) — macOS only

## Requirements

- macOS 15 (Sequoia) or later
- Apple Silicon Mac (aarch64-darwin)
- Xcode with Swift 6 toolchain

## Important: Replit Limitations

This project is a **macOS-native desktop application** and **cannot be built or run in Replit's Linux environment**. It depends on:
- SwiftUI (macOS-only UI framework)
- CoreAudio / HAL (macOS-only audio system)
- A custom C-based virtual audio driver
- macOS entitlements and sandboxing configuration

Replit is useful for **browsing, reading, and editing** the source code. To actually build and run the app, you need a Mac with Xcode and Swift 6.

## Building Locally (on macOS)

```bash
# Enter development environment
nix develop

# Build the app and package it
./bundle.sh

# Or build with Swift directly (requires Xcode toolchain)
swift build              # Debug build
swift build -c release   # Release build
swift test               # Run all tests
```

## Project Structure

```
src/
  app/        - App entry point and state coordination (EqualiserStore)
  dsp/        - Biquad DSP engine and coefficient math
  pipeline/   - Audio processing pipeline (shared memory & HAL input capture)
  device/     - CoreAudio device enumeration, volume control, change detection
  driver/     - Virtual audio driver lifecycle management
  ui/         - SwiftUI views (eq, meters, presets, settings, routing)
  routing/    - Audio routing strategies (Automatic vs Manual)
driver/       - C source for the custom virtual audio driver (BlackHole fork)
tests/        - XCTest suite mirroring src/ structure
docs/         - Architecture, development guides, user documentation
resources/    - App icons and assets
```

## Key Architecture

- **EqualiserStore** — central state coordinator, delegates to feature modules
- **BiquadFilter / BiquadMath** — pure DSP engine using vDSP for real-time safety
- **PipelineManager** — manages audio capture pipeline lifecycle
- **RoutingMode** — strategy pattern for automatic vs manual device routing
- **DriverManager** — manages the virtual audio driver installation and lifecycle

## User Preferences

- Use British English spelling (equaliser, behaviour, optimised)
- Follow SOLID and DRY principles
- Protocol dependencies over concrete types (protocols use `-ing` suffix)
- Test through public API only; use real instances for integration tests
