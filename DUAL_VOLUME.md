# BitChord 1.0.2: Dual Volume (iOS)

This branch retains the v1.0.2 playback engine, audio-session settings and mixed audio playback.

## Controls

- Short touch or ordinary drag on the volume track: changes the **iOS system volume** through `MPVolumeView` (white upper bar).
- Touch and hold the same track for **0.42 seconds**: one selection haptic signals the handoff. Continue dragging without lifting your finger to change **BitChord-only gain** (orange lower bar).
- The orange bar always shows the independent app gain, even when the regular system-volume gesture is active.
- When system volume is zero the device stays silent regardless of BitChord-only gain.
- App gain is stored in `UserDefaults` as `bitchord_local_volume`, and applied by the existing `PlaybackController.applyOutputGain()` to both the Rust engine and Dolby renderer.
- The iOS volume button and Control Center remain system-volume controls.
- Accessibility offers separate actions to increase and decrease BitChord gain.

## What remains unchanged

`AudioSessionManager`, including `AVAudioSession.CategoryOptions.mixWithOthers`, is unchanged. Playback continues to use the existing Rust audio engine.

## Build / installation

GitHub Actions workflow: `.github/workflows/build-dual-volume-ipa.yml`

On success, download the artifact named `BitChord-1.0.2-DualVolume-unsigned-IPA` from the Actions run. The IPA is unsigned: sign it with SideStore or another installer compatible with your device. Its main bundle ID is `com.music.bitchord`, version `1.0.2`, build `41`, matching the user's provided main app ID with a higher build number. App data continuity also depends on matching team/signing entitlements; back up before installing.

## On-device QA checklist

1. Start BitChord and another music/video app in simultaneous playback.
2. Drag the white control normally: the iOS Control Center volume should change.
3. Hold the volume control until the haptic, and drag: the orange app-gain bar should change, but Control Center volume should remain stable.
4. Set app gain to 0 and verify only BitChord is silent.
5. Set system volume to 0 and verify both apps are silent.
6. Relaunch BitChord and verify the orange level persisted.
7. Re-test headphones, Bluetooth output, AirPlay, landscape and background playback.

The workflow can test compilation but cannot emulate the user's real SideStore and audio-route behavior. Verify on device before replacing a working installation.
