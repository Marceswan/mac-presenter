# Presenter

Presenter is a teleprompter for macOS. It listens to the microphone and scrolls the script while you speak.

## Requirements

- macOS 26 or later
- Apple Silicon (recommended)
- Xcode 27
- [xcodegen](https://github.com/yonaskolb/XcodeGen)

## Build and run

```
make run
```

## Tests

```
make test
```

## Keyboard shortcuts

| Shortcut | Action |
| --- | --- |
| Command-O | Open a script |
| Command-Return | Switch between editor and prompter |
| Space | Start or stop listening (prompter) |
| Command-L | Start or stop listening |
| Command-R | Go back to the start |
| Command-= or Command-+ | Larger text |
| Command-- | Smaller text |
| Shift-Command-M | Mirror text |
| Shift-Command-T | Keep window on top |
| Arrow keys, trackpad | Move the script by hand |

## How voice following works

- Speech recognition runs on the Mac with SpeechAnalyzer.
- The app aligns the last 6 spoken words with the script. Fuzzy matching accepts small recognition errors.
- A small step forward needs little evidence.
- A jump forward or back needs 3 or more matching words.
- Text in square brackets is a cue. The app skips cues and does not wait for you to say them.

## Privacy

The audio stays on the Mac. Presenter does not send audio or text to a server.
