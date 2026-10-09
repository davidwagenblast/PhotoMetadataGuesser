<p align="center">
  <img src="Resources/Icon/AppIcon-1024.png" width="160" alt="Photo Date Guesser icon">
</p>

# Photo Date Guesser

A macOS app that finds the photos in your Apple Photos library that **don’t have a real date**, such as scanned prints, and estimates **when they were taken**. You review every guess with a thumbnail and a checkbox. When you click **Apply**, only the checked photos get the new date. It is set through Apple’s PhotoKit, so the photo isn’t replaced, its other details stay as they are, and Photos’ database stays consistent.

It’s built for very large libraries (250,000+ photos).

## How it works

### 1. Find undated photos

The scan runs in two passes so it stays fast on huge libraries:

1. **Database pass.** It reads every photo’s library date from PhotoKit. A photo is flagged if it has no date, an impossible date, or a camera’s factory-default date (Jan 1 1970/1980/2000/2001 at midnight). It is also flagged if its date falls in a *scanning session* you entered, or if it’s in an album you marked “all undated.”
2. **File-header pass** (optional, on by default). This catches scans and imports. Photos gives a file with no capture date the date it was scanned or imported, so those photos *look* dated. The app reads only the first few hundred KB of each original file and checks for an EXIF `DateTimeOriginal`. It also recognizes scanner metadata (Epson FastFoto, VueScan, Photomyne, …). Files are never changed. Photos that have a GPS location are trusted by default, which skips most phone pictures.

Photos with a real date are skipped. Results are cached, so a re-scan doesn’t re-read files it already checked. Originals that are only in iCloud are counted as “couldn’t be checked” unless you allow downloads.

### 2. Group photos (optional)

Select photos and make a group, or accept a suggestion. Suggestions come from albums and from runs of sequentially numbered scans imported together. For each group you can say:

- **Same event** (all photos get one date) or **same era** (each photo gets its own date, nudged toward the group).
- Free-text notes, such as “Lake Tahoe trip, late 70s” or “xmas ’85”. Years, decades, ranges, seasons and holidays in the notes are understood.
- A year range and season, if you know them.
- Who’s in the photos, and roughly how old they are.

### 3. People & birthdays (optional)

Add people with their birth year (and month, if you know it), plus one or two reference photos of their face. If someone appears looking about 10 years old and was born in 1952, that points to about 1962. Their birth year is also a hard limit: they can’t be in a photo taken before they were born.

### 4. Estimate dates

Every clue becomes evidence: a year range, how strong the clue is, and sometimes a season or exact month.

| Clue | Examples |
|---|---|
| Filenames | `IMG_20190704_…`, `1985-07-04`, `July 1979`, `xmas 85`, `late 70s`, `circa 1975`, `FB_IMG_<timestamp>` (camera counters like `IMG_1987` are ignored) |
| Album names | “Grandma 1965”, “Summer ’78”, “1960s” |
| File format & camera | HEIC means 2017 or later, Live Photo 2015 or later, RAW 2000 or later, iPhone model release years, early-digital resolutions |
| Color & tone | Sepia, black & white, the magenta shift of faded 1960s–80s prints |
| Border & paper | White print borders, instant-film frames, square 126/Instamatic prints |
| Scene (on-device Vision) | Snow, beach, autumn leaves, pumpkins, Christmas trees (used for the season) |
| **Claude visual analysis** (optional) | Fashion and clothing, hairstyles, eyeglasses, accessories, cars, phones and TVs, architecture and interiors, products, printed date stamps and photofinisher marks, paper and border styles, people’s apparent ages |
| Your groups & people | Notes, year ranges, seasons, who’s there and how old they are |

The clues are combined statistically, like weighing testimony. Each clue is a mixture: either it’s right (and narrows the year) or it’s noise. Combining them gives a probability for every year since 1830. Strong, specific clues (a printed date stamp, `1985-07-04` in a filename) outweigh vague ones (“black & white”). Clues that agree reinforce each other. The result is:

- the **most likely year**, an **~80% range** (e.g. 1972–1978), and a **confidence** (the chance the year is within ±2 years);
- a **season**, written as the month you asked for: **January** (winter), **March** (spring), **June** (summer) or **September** (fall). If the season is unknown, June is used. When a strong clue gives an exact month or date (a full date in a filename, “Christmas”), that’s used instead. You can turn this off in Settings.

#### Claude visual analysis

This is optional and off until you add an Anthropic API key in Settings. With it on, each photo (downsized to 1024 px by default) is sent to Claude with its filename, albums, on-device observations and your group notes. Photos you grouped go in the same request so they’re judged together. Your people’s reference photos (cropped to the face) are included so Claude can recognize them and estimate their age. Responses are structured JSON with year ranges, a season, any printed date, itemized clues and people sightings. On the review screen you can see every clue under **Why?**.

- Default model: **Claude Opus 5.5**. You can switch to Sonnet 5.5 or Haiku 5.5 (much cheaper for very large batches).
- The Estimate screen shows a cost estimate before you start, and the running cost while it works.
- The system prompt and reference photos are prompt-cached across requests. Rate limits and server errors are retried with backoff. If Claude can’t analyze a batch, those photos fall back to on-device clues and can be retried later.

### 5. Review & apply

Each card shows the thumbnail, the guess (“Summer 1976”), a confidence badge, the likely range, the current library date and a checkbox. You can change the year with a stepper or pick a different season. **Why?** lists every clue behind the guess. You can filter by confidence or group, bulk-check (e.g. “check all high-confidence”), and right-click to keep a photo’s current date.

**Apply** sets `PHAssetChangeRequest.creationDate` for the checked photos, in batches of 100. This is the same change as *Image ▸ Adjust Date and Time* in Photos:

- The original file is **not** rewritten or replaced.
- Location, people, albums, keywords, captions, edits and favorites are untouched.
- Photos makes the change itself, so its database stays consistent and iCloud Photos syncs it normally.
- Each photo’s previous date is saved, and **History ▸ Undo** puts it back.

## Building

Requirements: macOS 14 Sonoma or later. You also need Apple’s free developer tools; the build script offers to install them if they’re missing.

### One line

Paste this into Terminal:

```bash
curl -fsSL https://raw.githubusercontent.com/davidwagenblast/PhotoMetadataGuesser/main/install.sh | bash
```

It downloads the latest source, builds the app, puts it in your Applications folder and opens it. Run the same command again to update.

If you already have the project folder, you can instead double-click **`Build Photo Date Guesser.command`**. It does the same thing from the files on your Mac.

### Other ways

- `./scripts/build-app.sh` builds and signs `build/Photo Date Guesser.app` without installing it. To sign with your Developer ID, set `SIGN_IDENTITY="Developer ID Application: …"`.
- To work in Xcode, generate a project with [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen && xcodegen generate && open PhotoMetadataGuesser.xcodeproj`.
- `swift test` runs the estimation-logic tests (needs full Xcode).

Every push is built and tested on GitHub Actions (macOS). The built app is attached to each run as an artifact.

> **Tip:** Back up your Photos library (Time Machine is fine) before applying dates to thousands of photos. Undo is available, but a backup is the safest net.

## Project layout

```
Sources/DateGuessCore/        Pure-Swift logic (unit-tested)
  TextClues.swift             filename / album / hint parsing
  FormatClues.swift           file format & camera clues
  VisualClues.swift           color, sepia/B&W, borders, aspect; scene → season
  PeopleAndUndated.swift      ages from birthdays, undated detection, group suggestions
  EvidenceFusion.swift        combining clues; group fusion
  ClaudeDating.swift          Claude request/response, prompt, cost estimate
Sources/PhotoMetadataGuesser/ The macOS app
  Photos/                     PhotoKit: scanning, header reads, writing dates
  Analysis/                   Vision + image stats, estimation pipeline
  Views/                      SwiftUI screens
Resources/                    Info.plist, entitlements, app icon
```

## Privacy

- Everything runs on your Mac unless you turn on Claude visual analysis.
- With it on, a reduced-size copy of each photo, its filename and album names, your group notes, and the names and face crops of people you added are sent to Anthropic’s API.
- Your API key is stored in the macOS Keychain.
- App data (scan results, groups, people, estimates, undo history) lives in the app’s container under Application Support.

## Limitations

- Only photos in your own library are considered. Shared-album items can’t be edited through PhotoKit.
- If you previously fixed a scan’s date in Photos (rather than in this app), its file still has no capture date, so the scan may flag it again. Right-click ▸ *Keep Current Date* hides it for good.
- Each rebuild of an ad-hoc-signed app may make macOS ask for Photos permission again.
- Estimates are estimates. The confidence badge and **Why?** panel are there to help you decide what to trust.
