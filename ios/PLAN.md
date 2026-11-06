# OnAir for iOS: port plan

Personal app, sideloaded. Fork `xls/OnAir`, branch `ios`. Sources: every **network radio** OnAir supports, tested first on an ANTSDR E310 as a
Pluto. USB radios are not possible on iOS. Receive and transmit, and all of OnAir's modes.

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

## Direction: native first

The app is a custom native iOS app on OnAir's engine. `core/` and `rust/` stay unchanged and keep merging from upstream. The interface moves to
native screen by screen, and any mode without a native screen falls back to its ImGui panel, so every mode keeps working.

Order: native shell and controls, then a native Metal spectrum and waterfall, then native screens for the modes in use, starting with FM. The
spectrum reuses the ImGui-free headers (`colormap.h`, `spec_pipe.h`, `spec_axis.h`, `tune_drag.h`, `wf_view.h`). Control logic that lives in
`app/` (start, rate and bandwidth planning, tuning, per-mode ticks) is called through `ios/host` while `app/` is linked, rather than rewritten.

## Native screens by kind of mode

183 modes share a few shapes, so each shape is one reusable SwiftUI screen, filled with data from the core. A mode with no native screen yet
uses its ImGui panel.

| Priority | Screen type | Modes | What it looks like |
|---|---|---|---|
| 1 | **Radio** | FM, AM, DAB/DAB+, DRM, HD Radio, General receiver | A radio: dial, presets, station name, RDS text, slideshow |
| 2 | **Map tracker** | ADS-B, AIS, APRS, UAT, Flarm, sondes, drones | MapKit map, moving targets, list, detail card |
| 3 | **TV** | DVB-T/T2/S/C, ATSC, ISDB, DTMB, IPTV, analog TV | Channels, player, guide, teletext, scan |
| 4 | **Ham transceiver** | SSB, CW, FT8, JS8, PSK, RTTY, SSTV, QO-100 | VFO, band and mode, S-meter, waterfall, log, transmit |
| 5 | **Texter** | Meshtastic, LoRa mesh, pagers, APRS messages, ACARS | Conversations, send where the mode allows |
| 6 | **Voice scanner** | P25, DMR, NXDN, TETRA, D-STAR, trunking | Talkgroups, active calls, scan list |
| 7 | **Satellite** | Meteor, NOAA, GOES, CubeSats, Iridium, Inmarsat | Passes, tracking, image gallery |
| 8 | **Sensors** | ISM, weather sensors, Zigbee, Z-Wave, LoRaWAN, IoT | Devices with latest readings |

All of them sit on a shared foundation, built first:

1. Native shell: status strip, Device, Spectrum, Mode and Settings tabs, Radio sheet.
2. Native Metal spectrum and waterfall, with drag-to-tune and pinch-to-zoom.
3. Typed data from C++ to Swift for each screen type: what the desktop panels already read from `RxTelemetry`, plus picture and audio status.
4. Background audio, so the app is usable day to day.

Supporting work, added when the screen type needing it comes up:

- **FFmpeg for iOS** (TV, DAB+, DRM, HD Radio audio), reusing `DECT2_FFMPEG_PREFIX` and `tools/package/build_ffmpeg_static.sh`.
- **Transmit.** libiio already includes the Pluto transmit path. Needs native TX controls with a clear on-air state and an explicit arm step.
  The operator is responsible for licensing and for the rules of each band.
- **More network radios** in the Radio sheet: SpyServer, KiwiSDR, SDR++ server, and others.
- **Add-on decoders loaded at run time** (codec2, AAC, voice codecs): link them in with the same hook as libiio where the library is available.

## Native or ImGui

Use native controls for what the hand touches, and ImGui for what the eye reads. Native controls hold no receiver logic: they read and set
the same C++ state and call the same functions as the desktop's controls.

| Native (SwiftUI, UIKit gestures) | C++ ImGui |
|---|---|
| Bottom tabs, page chips, status strip, sheets and drawers | Spectrum and waterfall drawing, until the native Metal view replaces them |
| Spectrum gestures: drag to tune, pinch to zoom, tap, long press | Plots, constellations, meters, ionograms |
| Start and stop, frequency entry, volume, gain, mode picker | Decoded text, tables, maps and each mode's result panels |
| Source and radio setup, text fields | The long tail of mode-specific panels (183 modes) |
| Settings, using the data in `app/ui/settings_table.h` | Anything not yet moved to native |

A control moves to native when people use it often or ImGui handles it badly on touch. Rarely used panels stay in ImGui: rewriting them would
be new code to maintain and would drift from upstream.

## What the build tests showed

Run on Xcode 27.1, iOS 27.1 SDK. UI prototype code is in `ios/spike/`.

| Question | Result | Status |
|---|---|---|
| Does `dect2core` build for iOS? | Yes, device and simulator. About 1,350 objects, 4 failed before small fixes. Rust built unchanged after the target mapping. | Built and linked |
| Size? | About 28 MB linked and dead-stripped. Full build 4 to 7 minutes on 8 cores. | Measured |
| Does the engine run? | Yes on the simulator with the RemoteIO backend (`core/src/audio/audioout_ios.mm`): synthetic FM locks at 52 dB SNR in stereo with RDS, and audio plays in real time. The miniaudio abort is gone. | Measured on simulator and iPhone 18 Pro Max; sound heard on the phone |
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
- Use the touch shell (`app/ui/touch*.cpp`) as the first working UI and as the fallback for pages not yet native, through the `touch::setShellHost` hook.
- Put native gesture recognisers over the Metal view for the spectrum, and send results to the existing tuning and zoom logic (`app/gfx/tune_drag.h`).

## Pluto

Uses stock **libiio 0.26**, the same library and version as the desktop and the radio's iiod. `tools/build_core.sh` fetches it and builds it
for iOS unchanged, with the network backend only and the SDK's libxml2. `core/src/source/source_plutosdr.cpp` is unchanged.

iOS cannot load a loose library, so the build generates a table of libiio's functions (`iio_symbols.c`), and `DynLib` in
`core/src/source/native_common.h` looks them up there. That is the only shared-code change.

**Principle for this port:** reuse existing libraries and OnAir code, write only what iOS needs, and keep shared-file edits small so upstream
changes keep merging.

Checked against the real radio at `192.168.10.9`, an ANTSDR E310 (reports as ANTSDR Rev.C; Zynq 7020, AD9361, firmware v0.39-1-g7bcc-dirty, iiod 0.26):

- The app receives a real FM station through it on the simulator (TRIPLE M, 104.9 MHz, locked, stereo, 60 dB SNR) and on the iPhone.
- Samples are little-endian `S12/16`. `lpc` has four channels, voltage0 to voltage3, so a second RX path exists.
- `frequency_available` is 70 to 6000 MHz. Sample rate is 2.083 to 30.72 Msps.
- A test client on the Mac over Wi-Fi 6E received 9.7 Msps sustained with 256 Ki-sample buffers and 15.2 Msps with 1 Mi-sample buffers,
  over 1 to 2 second runs. Larger buffers matter.

## rtl_tcp

`core/src/source/source_rtltcp.cpp` uses plain BSD sockets with no library and should work unchanged, including its reconnect loop. Add
`NSLocalNetworkUsageDescription`, and report a denied permission as its own error rather than "wrong address".

## Bandwidth limits the UI cannot fix

| Mode | Rate needed | rtl_tcp (max 2.56 Msps) | Stock Pluto over USB-gadget network (3 Msps) | ANTSDR on Ethernet |
|---|---|---|---|---|
| FM | 2.4 Msps | Yes | Yes | Yes |
| DAB | 2.048 Msps | Yes | Yes | Yes |
| DVB-T, ATSC, ISDB-T | At least 6.5 to 7.9 Msps | **No** | **No** | Possibly, see below |

DVB-T at 7.9 Msps is about 253 Mbit/s in 16-bit samples. The ANTSDR delivered 310 to 487 Mbit/s to the Mac over Wi-Fi 6E in short runs, so
this radio may carry it, unlike a stock Pluto. Not yet measured: the same rate to the iPhone, sustained for minutes, and whether the phone can
decode it in real time. TV pages can still be built and tested with the built-in synthetic signal.

## Phases

Each phase ends with something runnable.

### 1. Project and core (done)
- Create `ios/` Xcode project, build script, and driver CMake.
- Apply the small shared-file edits: `cmake/OnairRust.cmake`, `CMakeLists.txt`, `core/src/engine/updater.cpp`, `core/src/power/power_apple.mm`.
- Replace miniaudio on iOS with a small RemoteIO backend (`audioout_ios.mm`) behind the existing interface, and configure `AVAudioSession`.
- Stub FFmpeg, libusb and libhackrf. Set `DECT2_BUNDLE_CODEC2=OFF`.
- **Done when:** the engine plays the synthetic FM signal through audio on a real iPhone.

### 2. Real radios
- Pluto through libiio, reached from the test screen. Works on the iPhone over Wi-Fi: a real FM station through the ANTSDR E310, heard on the phone.
- Connect rtl_tcp to a real server over Wi-Fi.
- **Done when:** FM from each radio plays on the phone for 30 minutes with no dropped-sample warnings.

### 3. The existing UI on the phone (done on simulator; tested by hand)
- Apply `ios/spike/ui/`: GLFW shim, `main.cpp` split into init/frame/shutdown, `gfx_metal.mm` host layer, power and AirPlay stubs.
- Link `app/` with `dect2core`, plus `onair_web` or a stub. Disable updater, plugins, webshare and Discord.
- Forward touch and `UIKeyInput`, and add the clipboard hooks.
- Avoid the blocking `refreshDevices` at startup (`app/main_start.cpp:80`), which risks the iOS watchdog.
- **Done when:** the unchanged touch shell runs full-screen on the iPhone with the synthetic signal, and the spectrum responds to touch.

### 4. Navigation shell
- SwiftUI status strip, custom bar, chip row, slot-sized view.
- `ios/host` C API: `set_page`, `list_pages`, state for the strip, start/stop, and setters for the native controls.
- Native Source, Gain, Tuner and Mode pages, plus spectrum gestures. Their ImGui versions stay available until the native ones work.
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
brew install cmake ninja pkg-config hackrf libusb ffmpeg xcodegen   # hackrf, libusb and ffmpeg: headers only; libiio is fetched by the script
rustup target add aarch64-apple-ios aarch64-apple-ios-sim
ios/tools/build_core.sh            # ios/build/OnAirCore.xcframework
cd ios && xcodegen                 # OnAir.xcodeproj
```
