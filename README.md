# MacbookDuo

An iPhone Duo-style fold transition for the MacBook lid.

While you move the lid, the screen freezes at the state it was in, blurs progressively,
and **holds the angle it had in space** — the display physically reorients around the
image rather than the image following the display. Once you hold the lid still, the
content swings back into alignment and comes into focus, crisp and live.

This mirrors what Apple does on the iPhone Duo, where the UI stays locked in space while
the hardware folds around it, with a progressive blur and darkening carrying the
transition instead of an abrupt cut.

## How it works

| Stage | What happens |
| --- | --- |
| Idle | A 2 fps ScreenCaptureKit stream keeps one clean frame of the built-in display ready. No overlay is on screen. |
| Engage | Once the lid passes the 2.5° wobble dead zone, that frame is placed in a click-through overlay, pixel-aligned with the live screen — the moment of engagement is invisible. |
| Fold | The plate counter-rotates about the real hinge axis, below the bottom edge of the image, so it keeps its former world-space angle. Past `worldLockKnee` the rotation eases toward its ceiling rather than stopping at it, so a wide fold keeps responding. Each pixel is blurred in proportion to **how far it has actually been displaced** from where it sits on the real screen — so a lid held near its original angle stays crisp everywhere, and the top blurs most simply because it swings through the widest arc. The frame's border pixels are carried outward past the edge of the display and fade across that whole margin, joining the picture to the black around it with no seam and without anything being painted over the real content. The angle the plate is drawn at eases toward the measured one, turning the sensor's whole-degree reports into continuous motion. |
| Resolve | The lid holds still for 0.28 s, then the content swings from the angle it was holding to the lid's new angle over 0.55 s. There is no separate step to take the blur away: the blur is a function of displacement, so arriving at the new angle *is* arriving at zero blur, and the parts that moved furthest come back into focus last. The plate only fades over the final quarter, to cover whatever changed on the live screen while the lid was moving. |

The fold and the return are driven from the same loop, which runs at `activePollHz` for
both — the return is an animation, not an idle state, and playing it at the idle rate is
what it looks like when the screen appears to stutter on its way back.

The lid angle comes from the internal HID sensor (`las`, usage page `0x20`, usage `0x8A`),
present on MacBooks from roughly 2019 onward. It needs no permission and reports degrees
directly. Polling runs at 20 Hz at rest and 60 Hz while moving.

Only the built-in display is affected — external monitors do not fold.

## Build and run

Xcode is not required; the Swift toolchain from the Command Line Tools is enough.

```sh
./build-app.sh --install
```

That builds the app, installs it to `/Applications`, and launches it. Plain
`./build-app.sh` builds into `./build` without installing.

On first launch macOS asks for **Screen Recording** permission. It is required: the effect
works by freezing a picture of your screen. Grant it under
*System Settings → Privacy & Security → Screen Recording*, then relaunch.

### Why the permission prompt can come back

Without an Apple code signing certificate the app can only be **ad-hoc signed**, and
every rebuild produces a different code hash. macOS ties the Screen Recording grant to
that hash, so after a rebuild the old entry is still listed and switched on but no longer
matches the app that is running — and you get asked again. `./build-app.sh --install`
clears the stale entry so you are asked once, cleanly. As long as you do not rebuild, the
grant sticks.

The app lives in the menu bar with no dock icon. The menu shows the live lid angle and
offers **Preview fold effect**, which plays the transition without touching the lid.

### Start at login

```sh
cp -R build/MacbookDuo.app /Applications/
osascript -e 'tell application "System Events" to make login item at end with properties {path:"/Applications/MacbookDuo.app", hidden:true}'
```

## Tuning

Every constant that shapes the feel lives in [Config.swift](Sources/MacbookDuo/Config.swift):

- `deadzoneTravel` — degrees of wobble ignored before the effect engages (2.5°)
- `fullStrengthTravel` — fold distance that reaches peak blur (22°)
- `maxBlurRadius`, `maxDarkening` — peak blur and dimming
- `worldLockFactor` — 1.0 locks content fully in world space; lower values let it drift with the lid
- `settleSpeed`, `settleDwell` — how slow, and for how long, the lid must be before the screen resolves
- `hingeOffsetBelowScreen` — how far below the image the rotation axis sits (26 pt)
- `blurPerPointOfDisplacement`, `maxBlurRadius` — blur per point a pixel has moved, and its ceiling
- `edgeExtension` — how far the frame is carried past the display and faded out (170 pt)
- `angleSmoothing` — how hard the drawn angle is smoothed against the sensor's one-degree steps
- `worldLockKnee`, `maxCounterRotation` — how far the tilt tracks the lid exactly, and the ceiling it eases toward beyond that
- `eyeDistanceInScreenHeights` — viewing distance that sets how strongly the tilt keystones the image; smaller bends it more
- `resolveDuration` — how leisurely the screen swings back to the new angle
- `compensateCoverageWhenClosing` — scale the content up while closing so the backing never shows, at the cost of the two directions no longer matching (off)

## Debug flags

```sh
./build/MacbookDuo.app/Contents/MacOS/MacbookDuo --demo   # play a synthetic fold
DUO_STRENGTH=0.5 DUO_TRAVEL=10 ./build/MacbookDuo.app/Contents/MacOS/MacbookDuo --hold  # freeze one point of the transition
```

## Requirements

- macOS 14 or later
- A MacBook with a lid angle sensor
- Screen Recording permission
