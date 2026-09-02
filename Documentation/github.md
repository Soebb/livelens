# 🚀 Publishing LiveLens to GitHub

Everything you need to take this working tree to a clean, professional public
repository: the repo identity, the exact commands, what never gets pushed,
and the accuracy notice that ships with the project.

---

## 1. Repository identity

| Field | Value |
|---|---|
| **Repository name** | `livelens` |
| **Visibility** | Public |
| **Initialize with** | **Nothing** — no README, no `.gitignore`, no license (all exist locally) |

**Description** (fits GitHub's 350-char limit, reads well in search results):

> Real-time, system-wide translated subtitles for Android — 100% on-device. Whisper (sherpa-onnx) captures any app's audio and renders live captions over it. No cloud, no accounts, no telemetry.

**Topics** (add after the first push):

```
android   flutter   whisper   sherpa-onnx   on-device   subtitles
translation   speech-to-text   live-captions   privacy
```

> The lowercase `livelens` name matches Flutter/Android conventions
> (`dev.livelens.livelens` package, pubspec name, existing README clone URL).
> GitHub is case-insensitive for repo names, so `LiveLens` also resolves —
> but lowercase keeps URLs and clone commands consistent.

---

## 2. ⚠️ Accuracy notice — read before publishing

> [!IMPORTANT]
> **About transcription & translation quality.** The bundled engine is
> **Whisper `base` (int8)**, chosen to fit real-time decoding on phone
> hardware. **Accuracy for non-English transcription and translation is
> limited and not fault-free.** This is a property of the model size, not a
> bug in LiveLens.
>
> For materially better results, either:
>
> - **On-device:** switch to a larger tier (small/medium) in the app's
>   Models screen — faster devices only; or
> - **Server-backed:** run **Whisper `large-v3` on a VPS** and stream audio
>   to it **over a WebSocket**, using the server purely as a transcription
>   backend. This trades the "fully on-device" privacy guarantee for quality.
>
> English transcription is where the bundled model performs best. Manage
> expectations accordingly — and please don't file "wrong words in Japanese
> videos" as a code bug.

---

## 3. What gets pushed — and what must never leave this machine

### ✅ Pushed (source of truth)

| Path | Why |
|---|---|
| `lib/` | All Dart app code (controller, screens, bridge, data, design) |
| `test/` | Dart + widget test suite |
| `android/` (minus build outputs) | Kotlin sources, Gradle config, manifest, resources, tests |
| `assets/fonts/`, `assets/icon/` | Font stack + app icon (small, build-time required) |
| `pubspec.yaml`, `pubspec.lock` | Dependency manifest — lock file included **on purpose** (app, not library) |
| `android/app/src/main/jniLibs/` | Vendored sherpa-onnx `.so` libraries — required for an out-of-the-box buildable repo |
| `Documentation/*.md` | PRD, architecture, design, checklist, this guide |
| `README.md`, `LICENSE`, `.gitignore`, `.metadata`, `analysis_options.yaml` | Repo essentials |

### 🚫 Never pushed (already gitignored — verify before the first push)

| Path | Reason |
|---|---|
| `assets/sherpa-onnx-whisper-base/`, `assets/sherpa-onnx-silero-vad/` | **~160 MB of model weights** — users download them on first launch |
| `build/`, `android/build/`, `android/app/.cxx/` | Build artifacts |
| `android/key.properties`, `*.jks`, `*.keystore` | **Signing secrets** — committing these is the classic repo leak |
| `.dart_tool/`, `.idea/`, `*.iml`, `*.log` | Tooling state & temp logs |

---

## 4. The exact commands (copy → paste, in order)

> **One-time prerequisite:** on [github.com/new](https://github.com/new)
> create an **empty** repository named `livelens` — do **not** tick any
> initialization checkboxes, otherwise the first push will conflict.

```powershell
# ── Run from the project root: d:\LiveLens ──────────────────────────────

# 1) Verify nothing forbidden is tracked (skim the output — no models,
#    no keystores, no build folders)
git status

# 2) Stage everything and commit
git add -A
git commit -m "feat: LiveLens — real-time on-device translated subtitles for Android"

# 3) Connect your GitHub account's repo (replace <your-username>)
git remote add origin https://github.com/<your-username>/livelens.git

# 4) Push as the main branch
git branch -M main
git push -u origin main

# 5) Tag the pre-alpha milestone and publish it
git tag -a v0.1.0 -m "Pre-alpha: core pipeline, overlay, models, language modes"
git push origin v0.1.0
```

That's it — the repo is live. If `git push` asks for credentials, use a
**Personal Access Token** (GitHub → Settings → Developer settings → Tokens)
as the password, or run `gh auth login` once if you have the GitHub CLI.

> **Already have a remote?** If `git remote add` says the remote exists, just
> update it instead: `git remote set-url origin https://github.com/<your-username>/livelens.git`

---

## 5. After the first push (5-minute polish on github.com)

1. **About panel (⚙ next to the repo name):** paste the description from
   section 1, add the website link if you ever get one.
2. **Topics:** add the ten topics listed in section 1.
3. **Releases:** draft a release from tag `v0.1.0` and attach the APK from
   `build/app/outputs/flutter-apk/app-release.apk` (~207 MB) so people can
   try the app without building it. Rename the artifact
   `livelens-v0.1.0-android.apk` for a professional look.
4. **CI (optional but recommended):** `.github/workflows/ci.yml` already
   exists in the tree and runs `flutter analyze` + `flutter test` on every
   push — confirm the first Actions run is green.

---

## Checklist

- [ ] Empty repo `livelens` created on github.com (nothing initialized)
- [ ] `git status` verified — no models, keystores, or build artifacts tracked
- [ ] Commit + push commands from section 4 executed
- [ ] Description & topics set, release v0.1.0 tagged with APK attached
- [ ] Accuracy notice (section 2) reflected in the repo README/About

