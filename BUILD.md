# Kreyzi Obfuscator — Android Studio Build Guide

## Requirements
- Android Studio Hedgehog (2023.1) or newer
- Android SDK 34 + Build Tools 34
- Java 8+ (bundled with Android Studio)
- Gradle 8.4 (auto-downloaded by wrapper)

---

## Steps

### 1. Open the project
```
File → Open → select the KreyziObfuscator/ folder
```
Android Studio will auto-sync Gradle on first open.

### 2. One-time: add the Gradle wrapper JAR
Android Studio will prompt you — click **"Add Gradle Wrapper"** if it appears,
or run in the terminal inside Android Studio:
```
gradle wrapper --gradle-version=8.4
```

### 3. Build debug APK
```
Build → Build Bundle(s)/APK(s) → Build APK(s)
```
Output: `app/build/outputs/apk/debug/app-debug.apk`

Or via terminal:
```bash
./gradlew assembleDebug
```

### 4. Install on device
```bash
adb install app/build/outputs/apk/debug/app-debug.apk
```

---

## What's inside
| Feature | Detail |
|---|---|
| Presets | Light, Medium, Hard, Minimal, CustomBVM1 |
| Lua Version | LuaU / Lua 5.1 / config default (radio buttons) |
| Input | Paste, load from file, char/line counter |
| Output | Copy to clipboard, Save .lua, Share |
| Logs | Live pipeline log panel |
| Engine | LuaJ 3.0.1 (pure-Java Lua runtime, no Termux) |
| All steps | All Kreyzi/Prometheus steps bundled as assets |

---

## How it works
1. On first launch, all 110 Lua source files are extracted from `assets/lua/` → `filesDir/lua/`
2. `ObfuscatorEngine.java` spins up a **LuaJ** globals environment
3. Injects `KREYZI_BASE`, `KREYZI_SOURCE`, `KREYZI_CONFIG`, `KREYZI_LUAVER` globals
4. Executes `android_entry.lua` which patches `debug.getinfo`, sets `package.path`, then calls `Prometheus.Pipeline:fromConfig(config):apply(source)`
5. Reads `KREYZI_OUTPUT` / `KREYZI_ERROR` back from Lua globals

## Troubleshooting
- **"too many registers"** crash → same as desktop Kreyzi, reduce ConstantArray chunk size in the config
- **Slow on first run** → asset extraction (~110 files). Subsequent runs are instant.
- **Black spinner text** → MIUI/OneUI theming; works fine on stock Android
