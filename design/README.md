# Side Eye artwork

- `app-icon.png`: the app icon source, a transparent 1254 × 1254 PNG.
- `menu-bar-icon.svg`: the menu bar template icon, hand-authored on an 18-point grid with `currentColor` fills and a transparent eye cutout.
- `blink/`, `blink-preview.html`: the six blink frames and a playback preview, exported by `python3 scripts/generate-icons.py`.
- `dmg-background.svg`: the installer window's background. `generate-icons.py` exports it as `dmg-background.tiff` (1× and 2×), which `scripts/make-dmg.sh` uses. The arrow lines up with icon positions set in that script.
- `animations-review.html`: the four state animations, with playback, slow motion and scrubbing.

## Motion

| Study | Trigger | Movement | Result |
| --- | --- | --- | --- |
| Caught you | Off-task verdict | Over 340 ms, narrow the eye opening to 62%, move the pupil 0.65 source units farther right, and turn red. | Hold the sharper side-eye until focus returns. |
| Just checking | Occasional normal blink | First blink at 1.8× speed (~157 ms), a ~65 ms gap, then a second blink at 2× speed (141 ms). The pair takes 363 ms. | Return to the same gaze. Proposed frequency: about one in five ordinary blinks. |
| There you are | Return to task | Lift the skeptical lid over 310 ms to 132% of normal opening; return the pupil and blend directly from red to green, without a neutral gray midpoint. After a brief hold, settle over 530 ms. | Normal open eye in the on-task green. |
| Rest your eyes | Break starts / ends | Close over 750 ms into a solid silhouette, with no eyelid line. Gently reopen over 770 ms when the break ends. | Keep the eye closed for the entire real break. The preview compresses this hold. |

Only the eye opening, pupil position, and state color change. The squircle, crown, pupil dimensions, and layout stay fixed. Tint values match the app's existing red and green. The double blink uses the normal blink's frame openings with faster timing. The app draws these vectors at native resolution, sampling transitions only while active. New states interrupt from the current pose; disabling motion immediately selects the correct static state.
