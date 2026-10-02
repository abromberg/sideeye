# Developing Side Eye

How to build Side Eye, how it decides whether you're on task, and how to release it. For what the app is and how to use it, see the [README](../README.md).

## Getting set up

You'll need Xcode 26 and [XcodeGen](https://github.com/yonaskolb/XcodeGen). The Xcode project is generated from `project.yml` and isn't checked in.

```sh
brew install xcodegen
scripts/build.sh --open        # build, install to ~/Applications, and launch
cd FocusCore && swift test     # tests for the judging logic and the log
```

`scripts/build.sh` quits any running copy of Side Eye before installing the new one.

**Signing.** Builds are signed ad-hoc by default, which means macOS treats every build as a new app and asks for Accessibility again. To keep your permissions across rebuilds, sign with your own Apple Development certificate. Create `Config/Local.xcconfig` (it's gitignored):

```
DEVELOPMENT_TEAM = <your team ID>
CODE_SIGN_IDENTITY = <certificate name or SHA-1>
```

`security find-identity -v -p codesigning` lists the certificates you have.

**API key.** The app reads your OpenRouter key from the Keychain, but `OPENROUTER_API_KEY` in the environment takes priority. The command-line tools only read the environment variable. Keep the key in a gitignored `.env` and load it with `set -a; source .env; set +a`.

**Trying the UI without a session.** Demo mode shows each state with made-up data and never touches your settings or log:

```sh
open -a "Side Eye" --args --demo=on        # also idle, unsure, off, break, credit, credit-idle, error, or cycle
open -a "Side Eye" --args --demo=off -panelStyle compact -demoTitle "Some window"
open -a "Side Eye" --args --show-welcome   # or --show-settings, --show-menu-preview
```

## Where things are

| Folder | What's in it |
| --- | --- |
| `App/` | The macOS app: the menu bar, floating window, Settings, welcome window and update checks |
| `FocusCore/` | A Swift package with the judging pipeline, the model calls, the log and the tests. It has no UI, so most changes can be tested with `swift test` |
| `FocusCore/Sources/focuseval/` | `focuseval`, the command-line tool for checking and tuning judgments |
| `design/` | Source artwork for the icons and previews of the eye's animations |
| `scripts/` | Building, releasing and icon generation |
| `Config/` | Signing settings |

## How Side Eye decides

Every time the window in front changes, Side Eye asks one question: does this window fit the task? It starts with the cheapest evidence and only looks harder when it isn't sure.

1. **Notice the change.** `App/ContextWatcher.swift` watches for app switches and window or title changes through the Accessibility API, and checks again every 45 seconds. Each change becomes a snapshot of the app, the window title and the web address.
2. **Judge from the title.** `FocusCore/Judge.swift` sends the task and the snapshot to Jev through OpenRouter's Decisions API (`POST /api/v1/systemone`). Jev answers with a probability that the window is on task. At 0.6 or above it counts as on task, at 0.35 or below it's off, and anything in between needs more evidence. Settings → Judging moves those lines.
3. **Look harder when unsure.** `FocusCore/Pipeline.swift` adds evidence one step at a time and asks Jev again each time:
   - the window's text from the Accessibility API, using the page's main content when it has one, so an email isn't buried under the inbox sidebar;
   - text read from a screenshot of the window with Vision, on the Mac;
   - a description of the screenshot from a vision model (`~deepseek/deepseek-flash-latest` by default).

   Jev always makes the decision; the other models only gather evidence. An off-task verdict made from the title alone is checked once more against the window's text, because titles often don't say what an email or chat is about.
4. **Show it.** `App/AppModel.swift` turns an off-task verdict red, but not during the first 5 seconds after Start. If a window is still in between after every step, it shows yellow (*probably on task*) and never turns red.

Results are cached per window, except close calls, so a borderline window gets judged fresh each time you return to it.

### The task brief

The task name alone is often too short to judge by. "Northwind launch" doesn't tell Jev which docs, people or tools belong to it. So when a session starts, `FocusCore/TaskBrief.swift` makes one call (`openai/gpt-6-luna` by default) to write a short brief: what the task is related to, what it involves, what counts, and what doesn't. That brief goes to Jev with every window.

The brief is written from:

- **Your recent tasks.** Past tasks with the same meaning or a shared company, person or project help define what counts. Unrelated ones become *not this*, which keeps one project's doc from passing for another's.
- **Windows you've confirmed.** **I'm on task!** and **Yes, on task** rewrite the brief with that window as an example, so similar windows count too. Examples are cleaned of whatever an app repeats in every title, like a workspace or account name (`FocusCore/TitleChrome.swift`), so one confirmed Slack channel doesn't make all of Slack count.
- **What you're actually doing.** While an on-task window is in front, its text is re-read every 10 seconds. When you leave it with 25 or more new words, the brief is rewritten, at most every 3 minutes. That's what lets a task like *750 words* count the doc you were just writing about. A verdict waits up to 6 seconds for a rewrite in progress, then uses the previous brief.

The brief isn't shown in the app. `focuseval review` prints the briefs each task was judged with.

### What's logged

Everything is kept in a SQLite database at `~/Library/Application Support/Side Eye/focus.sqlite` (`FocusCore/Store.swift`): sessions, window changes, every verdict with its probability and cost, and your corrections, which double as labels for tuning. Window text and screenshots aren't stored unless *Debug mode* is on in Settings → Privacy. Then each window switch keeps the text read there, and every model call keeps its request, response, model, latency, cost and any screenshot.

Emails, phone numbers, card numbers, Social Security numbers and API keys are removed before anything is sent (`FocusCore/Redactor.swift`).

## The eye

The app icon and the menu bar eye come from two source files: `design/app-icon.png` and `design/menu-bar-icon.svg`. After changing either one, or the blink timing in `scripts/generate-icons.py`, run:

```sh
brew install librsvg            # once
python3 scripts/generate-icons.py
```

That exports every app icon size, the menu bar frames and the Swift blink timings in `App/SideEyeBlink.swift`.

In the app, `App/EyeIcon.swift` draws the eye as vectors, and `App/EyeMotion.swift` animates it. It blinks every 8 to 14 seconds, sometimes twice. It narrows and turns red when you drift, lifts and turns green when you come back, and closes during breaks. Reduce Motion and the *Animate* settings switch the movement off but keep each state's look. Open `design/animations-review.html` to replay the animations, and see `design/README.md` for their timings.

To check the animations still behave after a change:

```sh
mkdir -p build
swiftc App/SideEyeBlink.swift App/EyeMotion.swift App/EyeIcon.swift scripts/check-eye-motion.swift -o build/check-eye-motion
build/check-eye-motion
```

## Releasing

Releases are built on a Mac, signed with a Developer ID, notarized by Apple and published as GitHub releases. Installed copies find new versions through [Sparkle](https://sparkle-project.org), which reads `appcast.xml` from the latest release.

One-time setup:

1. A **Developer ID Application** certificate in your login Keychain.
2. Notarization credentials, saved under the name `side-eye`:
   `xcrun notarytool store-credentials side-eye --apple-id <email> --team-id <team ID>`
3. The **Sparkle signing key** in your login Keychain. Its public half is `SUPublicEDKey` in `project.yml`. Every update has to be signed with this key, so back it up somewhere safe. If it's lost, existing installs can't be updated.

For each release:

1. Bump `MARKETING_VERSION` in `project.yml`, and always raise `CURRENT_PROJECT_VERSION`. Sparkle compares that number to decide what's newer.
2. Build, sign, notarize and write the appcast:
   ```sh
   DEVELOPER_ID="Developer ID Application: Experimental LLC (<team ID>)" scripts/release.sh
   ```
   `Side-Eye.dmg`, `Side-Eye.zip` and `appcast.xml` end up in `build/release/dist/`. The disk image is what people download; it opens to a window where they drag Side Eye into Applications. The zip is what Sparkle installs updates from. Both keep the same names every release, so the README's download link (`releases/latest/download/Side-Eye.dmg`) always points at the newest version. Finder lays out the disk image's window, so the first release from a Mac asks to let Terminal control Finder.
3. Publish with the `gh release create` command the script prints.

## Tuning with focuseval

`focuseval` replays your own log to show why Side Eye judged a window the way it did, and tests changes against it. Run it from `FocusCore/` with `OPENROUTER_API_KEY` set. Commands that look at your history read the app's log; pass `--db <path>` to use a copy instead.

A good place to start is labeling a day, then seeing how each strictness setting would have done:

```sh
swift run focuseval review                  # label today's windows on or off, longest-viewed first, then score the presets
swift run focuseval review --day 2026-09-30 --relabel
```

To see why a window got a verdict:

```sh
swift run focuseval judge "Draft the lease memo" "Google Chrome — https://x.com/home — Home / X"
swift run focuseval brief "Northwind launch"                  # the brief Start would write from your history
swift run focuseval brief "750 words" --text-window "Journal" --text-file entry.txt > brief.txt
swift run focuseval judge "750 words" "Helium — https://docs.google.com/x — Product strategy" --brief-file brief.txt
swift run focuseval chrome                                    # what each app repeats in every title
```

Windows are written as `App — URL — title`, or `App — title` when there's no web address.

To test a change against everything you've logged:

```sh
swift run focuseval replay --on 0.75 --off 0.25    # re-judge logged verdicts with different lines; lists windows you corrected
swift run focuseval context labels.tsv            # score hand-labeled windows with and without a brief
swift run focuseval debug --session 42            # a debug-mode session as it happened, with text and model calls
swift run focuseval debugeval --since 2026-09-30  # replay debug-mode windows under different pipeline and brief variants
```

`context` takes a tab-separated file of `task`, `window` and `on`, `off` or `?`. Keep files like that in `FocusCore/evals/`, which is gitignored, because they describe what you've been working on.

`JEV_MODEL` and `BRIEF_MODEL` swap the models the tool uses, and `BRIEF_PROMPT_FILE` tries a different prompt for writing briefs.
