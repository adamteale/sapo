# Manual Test Checklist (run before tagging a release)

> Items 3-15 require the human at the keyboard; CLI items assume audio is playing.

1. `swift test` — all unit tests pass.
2. `DMG=1 ./scripts/build-app.sh` — DMG builds.
3. First launch of Stems.app: Gatekeeper ad-hoc flow works (right-click → Open).
4. `--list-taps` CLI: browser playing audio appears under APPLICATIONS.
5. `--record-app` CLI: 5s capture, afinfo shows ALAC/48k, plays back, source NOT muted.
6. `--record-mic` CLI: 5s capture non-empty.
7. GUI record with Chrome + mic: meters move, timer runs, stop writes session folder
   with manifest.json + 2 stems.
8. Quit Chrome mid-session: Chrome stem ends (endEvent processExited), session continues.
9. Kill -9 Stems mid-session: relaunch, session lists as partial, stems playable, exportable.
10. Sessions: preview plays a stem; export Combined M4A; QuickTime plays result.
11. Export grouped: Applications + Microphone files; individual: one per source.
12. Cleanup prompt (ask): delete stems keeps manifest; session still listed with 0 stems.
13. Settings: format WAV → new session writes .wav stems; launch-at-login toggles.
14. Low disk: fill volume (or fake small APFS quota) → start session shows warning.
    (If impractical, verify code path via unit-injected small threshold.)
15. Menu bar: Record with no prior selection opens window; red icon while recording.
16. Close the main window, then click Open Stems… in the menu bar — the window reappears.
17. Idle meters: with the window open and nothing recording, play audio in a
    browser — its row's meter bounces; stop playback — it falls flat.
18. Window gate: close (hide) the window — no meter processes remain
    (`--list-taps` still fine, CPU drops); reopen — meters resume.
19. Mid-session add: start recording mic only; tick a playing browser — a new
    stem appears in the session folder; manifest shows its later startTime.
20. Mid-session remove: untick the browser mid-recording — its stem ends with
    endEvent "userRemoved"; mic keeps recording; combined export aligns both.
21. Meter permission: fresh install, first window open triggers the mic prompt
    once; deny → permission bar; grant via Settings + Retry → meters start.
