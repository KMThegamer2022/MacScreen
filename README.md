# MacScreen

Use a Chromebook (or any device with Chrome) as a **wireless second screen for your Mac** — with touch.

MacScreen adds a real virtual monitor to macOS, streams it with hardware H.264 over your local network, and shows it in a web page. Touches on the receiving device become mouse clicks, drags and scrolls on the Mac.

- **Real extra display** — drag windows onto it like any other monitor.
- **Low latency** — ScreenCaptureKit capture → VideoToolbox H.264 → WebCodecs decode. Around 60 fps on a local network.
- **Touch control** — tap = click, double-tap = double-click, drag = drag/select, two-finger drag = scroll, two-finger tap or long-press = right-click.
- **Several screens** — every device that connects automatically gets its own virtual display, sized to that device's screen shape. Add `?screen=1` to the URL to share one on purpose.
- **Nothing to install on the receiver** — just open a URL in Chrome.

## Install

**One line (recommended)** — skips the "unidentified developer" prompt:

```bash
curl -fsSL https://raw.githubusercontent.com/KMThegamer2022/MacScreen/main/install.sh | bash
```

**Or** download `MacScreen-<version>.dmg` from [Releases](https://github.com/KMThegamer2022/MacScreen/releases), drag MacScreen to Applications, and the first time open **System Settings → Privacy & Security → Open Anyway** (the app is not notarized).

Requires macOS 13 or newer. Apple silicon and Intel builds are included (the Intel slice is untested).

## Use

1. Open MacScreen and press **Start**.
2. Grant **Screen Recording** (to capture the virtual screen) and **Accessibility** (so touch can control the Mac) when macOS asks. Re-open the app if it asks you to.
3. On the Chromebook, open the **https** address shown in the app, e.g. `https://192.168.1.20:8766`.
   - Chrome shows a certificate warning the first time (the certificate is self-signed): **Advanced → Proceed**.
   - HTTPS matters: Chrome only enables hardware H.264 on secure pages. The plain `http://…:8765` address works too but falls back to slower JPEG.
4. A virtual display appears on the Mac. Tap the ☰ button on the receiver for fullscreen, quality and stats.

Optional: turn on **Launch MacScreen when I log in** and **Start the second screen automatically** in the app.

## Wired / USB

MacScreen streams over IP, so "wired" means any network link between the two devices: Ethernet, a USB-Ethernet adapter on each side, or a direct cable that gives both a link-local address. The app lists every address it finds. A bare USB-C cable between a Mac and a Chromebook does **not** create a network link by itself. Wired setups are untested.

## Notes and limitations

- Uses Apple's **private CGVirtualDisplay API** to create the virtual monitor. It works on current macOS but is unsupported and could break in a future release.
- Release builds are ad-hoc signed and not notarized. macOS ties Screen Recording / Accessibility permission to the app's signature, so after updating you may need to re-grant them.
- Each extra display adds its own capture and hardware encode.
- There is no authentication: anyone on your network who opens the URL can see and control the virtual screen. Use it on networks you trust.
- Keyboard input from the receiver is not implemented.

## Build from source

Needs only the Xcode Command Line Tools (`xcode-select --install`), no full Xcode.

```bash
./build.sh                       # builds build/MacScreen.app
./scripts/make-release.sh 1.0.0  # builds dist/MacScreen.zip and dist/MacScreen-1.0.0.dmg
```

`build.sh` signs with an "Apple Development" identity if one is in your keychain (keeps permissions across rebuilds); otherwise it signs ad-hoc.

## How it works

| Piece | Tech |
| --- | --- |
| Virtual monitor | `CGVirtualDisplay` (private CoreGraphics API), resized in place |
| Capture | ScreenCaptureKit, one stream per display |
| Encode | VideoToolbox hardware H.264, low-latency rate control (JPEG fallback) |
| Transport | Built-in HTTP/HTTPS + WebSocket server (Network.framework), per-client back-pressure |
| Receiver | `web/receiver.html` — WebCodecs `VideoDecoder`, Pointer Events for touch |
| Input | `CGEvent` mouse and scroll events mapped to the display's bounds |

## License

MIT
