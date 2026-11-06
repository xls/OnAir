# OnAir for iOS: port plan

Personal app, sideloaded. Fork `xls/OnAir`, branch `ios`. Sources: **PlutoSDR over IP** and **RTL-SDR over rtl_tcp**, nothing else.

## Approach

Keep the code. `core/` and `rust/` (DSP, decoders, engine) and the C++ ImGui views in `app/` all stay. ImGui draws through its Metal backend
(already in the repo and already the macOS default) into one Metal view. SwiftUI adds only the navigation around it: the status strip, the
bottom bar, the page chips and native sheets.

```
+----------------------------------+
| SwiftUI  status strip            |  frequency, start/stop, level, mute: on every tab
+----------------------------------+
| SwiftUI  page chips              |  Source | Gain | Tuner | Mode | Display
+----------------------------------+
|                                  |
| MTKView: one ImGui context       |  draws the C++ panel for the current page
| sized to this slot               |
|                                  |
+----------------------------------+
| SwiftUI  Device Spectrum FM Sett |  third tab is named after the mode
+----------------------------------+
        | ios/host C API: init, frame, touch, set page, list pages, state
+----------------------------------+
| app/ (ImGui views, unchanged     |  GLFW replaced by a small shim
| where possible) + dect2core/Rust |  Pluto through a built-in iiod client
+----------------------------------+
```

## What the build tests showed

Run on Xcode 27.1, iOS 27.1 SDK. UI prototype code is in `ios/spike/`.

| Question | Result | Status |
|---|---|---|
| Does `dect2core` build for iOS? | Yes, device and simulator. About 1,350 objects, 4 failed before small fixes. Rust built unchanged after the target mapping. | Built and linked |
| Size? | About 28 MB linked and dead-stripped. Full build 4 to 7 minutes on 8 cores. | Measured |
| Does the engine run? | Yes on the simulator with the RemoteIO backend (`core/src/audio/audioout_ios.mm`): synthetic FM locks at 52 dB SNR in stereo with RDS, and audio plays in real time. The miniaudio abort is gone. | Measured on simulator; phone pending |
| Does `app/` build? | 371 of 376 files compile unchanged with a GLFW shim first on the include path. The other 5 are platform files, replaced or guarded in the prototype. | Compiled, not linked |
| Metal rendering? | Real `gfx_metal.mm` with ImGui and NV12 video in an MTKView on the simulator. | Screenshot confirmed |
| Full app, touch, keyboard, background audio, phone-width layout | Not run. | **Untested** |
| Pluto or rtl_tcp against a real radio | Not run. | **Untested** |

## Navigation

Four bottom tabs. Every tab uses the same pattern: a row of chips picks a page, the page is an existing C++ panel.

| Tab | Chips | Existing code |
|---|---|---|
| **Device** | Source, Gain, Tuner, Mode, Display, Decoder | `sidebar()` sections, `app/ui/ui2_shell.cpp:187`: `toolbarParts(a, Tb...)`, `modeList(a)`. Display is inline and needs moving into a function. |
| **Spectrum** | None at first; later Analysis views | `overviewTab` / `spectrumWaterfall`, `app/gfx/plots.cpp:1963`. Pinch zoom exists at `app/gfx/plot.cpp:290`. Rotating to landscape gives the whole screen. |
| **Mode** (named FM, TV, DAB...) | Whatever the mode has | `ModeUi` (`app/app.h:1107`) and `mainTabsInner` (`app/ui/main_tabs.cpp`) |
| **Settings** | iOS-relevant categories, Log | `settings_window`, filtered through `settings_table.h` |

Mode tab examples:

- **FM:** Radio, Scan, Analysis, History
- **TV:** Watch, Guide, Recordings, Teletext, Receiver, Stream, Scan, History

TV shows why the list must come from C++ and be flattened. Watch, Guide, Recordings and Teletext are a second level inside the TV tab
(`subNav` at `app/panels/tv.cpp:801`), below the main tab bar. Make both levels report their entries (`noteTab` already does this for tabs,
`subNav` needs the same; it is one function, `app/ui/widgets.cpp:215`, used in 73 files), hide both ImGui bars when hosted, and let Swift select an entry. A mode added later then needs no Swift change.

Placement of the rest of the desktop screen:

- Top bar (frequency, stop, ADC level, volume): the status strip. Tapping it opens the keypad or volume sheet.
- Right panel (station details, saved stations): first page of the Mode tab.
- Bottom analysis row (multiplex, RDS symbols, SNR): Analysis page of the Mode tab.
- Status bar and Log: expanded strip, and Settings.
- Tools list: left out at first. Add one at a time, under Settings or as Mode pages.

Design rules from the prototype:

- **One MTKView, one ImGui context.** `app/` has about 1,200 `static` state lines and `tickReceiver` runs inside drawing, so several contexts
  would fight each other.
- **Size the view to the slot**, not full-screen. The sheet placement in `app/ui/touch.cpp:39-62` works from `io.DisplaySize`, so this avoids
  safe-area plumbing.
- **No SwiftUI `TabView`** around the Metal view: it would re-parent it. Use a `ZStack` and a custom bar.
- Build on the touch shell (`app/ui/touch*.cpp`) and its gestures and sheets, using the `touch::setShellHost` hook from the prototype.

## Pluto

The desktop reaches a Pluto through libiio, loaded at run time. The repo has no iiod code of its own and no libiio.

**Decision: write a small iiod-over-TCP client** (port 30431) in `ios/`, about 300 to 500 lines on `core/src/net/tcp_client.h`, and expose it
through the same function table (`IioApi`, `core/src/source/source_plutosdr.cpp:11-46`). `source_plutosdr.cpp` stays nearly unchanged, so all
its tuning, gain and rate logic carries over. Cross-building libiio was rejected: it needs libxml2, which has headers but no confirmed link
library in the iOS SDK, and it would still need `DynLib` changes.

- Use two sockets, control and data, as libiio does, so a blocked refill cannot hold up a retune.
- Commands needed: `PRINT`, `TIMEOUT`, `READ`, `WRITE`, `SET ... BUFFERS_COUNT`, `OPEN`, `READBUF`, `CLOSE`.
- Stub the scan functions. Leave out `iio_buffer_push`, so no transmit.
- `IioApi::ok` requires the scan functions, and the loader needs a path that does not use `dlopen`.
- The protocol details came from a summary of libiio v0.26, not line-by-line reading. Capture real traffic from a desktop session and test
  against a real Pluto early.
- `192.168.2.1` is the USB-gadget link, unproven on iPhone. Assume Wi-Fi or Ethernet.

## rtl_tcp

`core/src/source/source_rtltcp.cpp` uses plain BSD sockets with no library and should work unchanged, including its reconnect loop. Add
`NSLocalNetworkUsageDescription`, and report a denied permission as its own error rather than "wrong address".

## Bandwidth limits the UI cannot fix

| Mode | Rate needed | rtl_tcp (max 2.56 Msps) | Pluto over USB-gadget network (3 Msps) | Pluto on a real network |
|---|---|---|---|---|
| FM | 2.4 Msps | Yes | Yes | Yes |
| DAB | 2.048 Msps | Yes | Yes | Yes |
| DVB-T, ATSC, ISDB-T | At least 6.5 to 7.9 Msps | **No** | **No** | Only on a fast link |

DVB-T at 7.9 Msps is about 253 Mbit/s in 16-bit samples, or about 126 Mbit/s in the 8-bit format that needs Tezuka firmware. That requires
something like a Pluto+ on Gigabit Ethernet plus strong Wi-Fi, and phone CPU load at that rate is unmeasured. TV pages can still be built and
tested with the built-in synthetic signal. DVB-S on a 1.5 Msym/s signal such as the QO-100 beacon is a lower-rate TV option.

## Phases

Each phase ends with something runnable.

### 1. Project and core
- Create `ios/` Xcode project, build script, and driver CMake.
- Apply the small shared-file edits: `cmake/OnairRust.cmake`, `CMakeLists.txt`, `core/src/engine/updater.cpp`, `core/src/power/power_apple.mm`.
- Replace miniaudio on iOS with a small RemoteIO backend (`audioout_ios.mm`) behind the existing interface, and configure `AVAudioSession`.
- Stub FFmpeg, libusb and libhackrf. Set `DECT2_BUNDLE_CODEC2=OFF`.
- **Done when:** the engine plays the synthetic FM signal through audio on a real iPhone.

### 2. The existing UI on the phone
- Apply `ios/spike/ui/`: GLFW shim, `main.cpp` split into init/frame/shutdown, `gfx_metal.mm` host layer, power and AirPlay stubs.
- Link `app/` with `dect2core`, plus `onair_web` or a stub. Disable updater, plugins, webshare and Discord.
- Forward touch and `UIKeyInput`, and add the clipboard hooks.
- Avoid the blocking `refreshDevices` at startup (`app/main_start.cpp:80`), which risks the iOS watchdog.
- **Done when:** the unchanged touch shell runs full-screen on the iPhone with the synthetic signal, and the spectrum responds to touch.

### 3. Real radios
- Connect rtl_tcp to a real server over Wi-Fi with the local network permission.
- Write the iiod client and connect to a real Pluto.
- **Done when:** FM from each radio plays on the phone for 30 minutes with no dropped-sample warnings.

### 4. Navigation shell
- SwiftUI status strip, custom bar, chip row, slot-sized view.
- `ios/host` C API: `set_page`, `list_pages`, state for the strip, start/stop.
- Split `sidebar()` into per-section functions. Report and hide `tabItem` and `subNav` entries.
- **Done when:** all four tabs work and the Mode tab's name and chips change when the mode changes.

### 5. Phone layout
This is likely the largest phase. The touch shell targets 800 x 480 and up; an iPhone is about 402 points wide, and it has never run there.
- Fix panels page by page, FM and Device pages first. Prefer stacking through `modepanel::panes`, and shared fixes in `app/ui/kit` over per-panel edits.
- Landscape spectrum.
- **Done when:** every page of the first mode set is usable one-handed on an iPhone.

### 6. Background and lifecycle
- `UIBackgroundModes: audio`, active audio session, silent audio for data-only modes.
- Keep logic running with a 10 Hz main-queue timer through the existing occluded path (`app/main.cpp:429`), because `tickReceiver` lives inside
  drawing. The shim must never report iconified.
- No GPU work in the background: force CPU in `core/src/dsp/gpu_ldpc.mm` and `gpu_viterbi.mm`.
- Save state when entering the background, because iOS can kill the app without warning.
- **Done when:** FM keeps playing with the screen locked for an hour and decoded data is intact on return.

### 7. Settings and first mode set
- Filter Settings to what applies on iOS. Hide the mode list down to the chosen set.
- First modes: FM, General receiver, ADS-B, AIS. These need no FFmpeg. Confirm the rates of the last two against the table above.
- Replace `curl`-based downloads with `NSURLSession` (`core/src/packs/packs.cpp`, `core/src/transcribe/models.cpp`) if map tiles or data packs are wanted.

### 8. Growth
- FFmpeg static build for iOS: TV video, plus AAC audio for DAB+ and DRM. Uses VideoToolbox through the existing player path.
- Then TV pages, more modes, tools, and iPad layout, as wanted.

## Known risks

1. The audio abort in phase 1 blocks all runtime testing, so it comes first.
2. Phone-width ImGui layout may cost more than everything else combined. If a panel will not fit, redesign that panel in C++ rather than moving it to Swift.
3. ImGui has no Dynamic Type or VoiceOver. Acceptable for a personal app.
4. Decoding load and battery on a phone are unmeasured.
5. Tracking upstream: keep shared-file edits small and guarded, so `upstream/main` merges stay easy.

## Build

```sh
brew install cmake ninja pkg-config hackrf libusb ffmpeg xcodegen   # hackrf, libusb and ffmpeg: headers only
rustup target add aarch64-apple-ios aarch64-apple-ios-sim
ios/tools/build_core.sh            # ios/build/OnAirCore.xcframework
cd ios && xcodegen                 # OnAir.xcodeproj
```

## Open questions

1. **Which Pluto?** Stock or Pluto+, and how it reaches the network, sets which modes are possible.
