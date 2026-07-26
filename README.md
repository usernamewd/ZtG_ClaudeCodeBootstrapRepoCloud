# Tactical Strike

An original round-based tactical FPS for Android in the competitive bomb-defusal
genre, playable offline against bots. Built with **Godot 4.5** (GL Compatibility
renderer) and exported as a **native Android APK** through Godot's official
Gradle build — no WebView, no web runtime, no hybrid framework.

- Two original competitive defusal maps with two bomb sites, mid, connectors and
  three-lane flow
- Bomb-defusal rounds, halftime side swap, full buy economy with loss bonuses
- 10 distinct firearms plus knife, four grenade types and gear
- Rigged, animated characters with locomotion blending and aim offsets
- Full-body first person: look down and see your own animated legs
- Bots with navmesh movement, buy logic, role behaviours and engagement AI
- Touch controls with repositionable HUD, optional gyro aim

## Requirements

| | Version |
|---|---|
| Godot | 4.5 stable (standard, not .NET) |
| JDK | 21 |
| Gradle | 9.5.1 (via the committed wrapper) |
| Android SDK | platform 35, build-tools 35.0.0 |
| Android NDK | 28.1.13356709 |

The Android build template committed under `android/` is pinned to **Gradle
9.5.1 + AGP 8.13.2** so it builds under JDK 21 on aarch64 Linux and Termux.

## Building from the CLI

```sh
# 1. Godot 4.5 + its export templates
#    (the templates provide android_source.zip, needed by the setup script)
godot --headless --version                      # expect 4.5.stable

# 2. Restore the parts of the Android template too large to commit (~200 MB of
#    godot-lib AARs). Run once after cloning.
./tools/setup_android_template.sh

# 3. Point Godot at your SDK/JDK once (editor settings, per machine)
cat > ~/.config/godot/editor_settings-4.5.tres <<'EOF'
[gd_resource type="EditorSettings" format=3]

[resource]
export/android/java_sdk_path = "/usr/lib/jvm/java-21-openjdk-amd64"
export/android/android_sdk_path = "/opt/android-sdk"
export/android/debug_keystore = "/root/debug.keystore"
export/android/debug_keystore_user = "androiddebugkey"
export/android/debug_keystore_pass = "android"
EOF

# 4. Import assets, then export
godot --headless --import
mkdir -p build
godot --headless --export-debug "Android" build/TacticalStrike.apk
```

The APK lands at `build/TacticalStrike.apk`, debug-signed and installable with
`adb install -r build/TacticalStrike.apk`.

### Building in Termux (aarch64)

Termux is the target build environment, which is why the wrapper is pinned to
Gradle 9.5.1 and the toolchain to JDK 21 — older AGP/Gradle pairs refuse to run
there.

```sh
pkg install openjdk-21 gradle unzip python
# Godot for aarch64: use a Termux-compatible 4.5 build, then as above.
export JAVA_HOME=$PREFIX/opt/openjdk
export ANDROID_HOME=$HOME/android-sdk
./tools/setup_android_template.sh
godot --headless --import
godot --headless --export-debug "Android" build/TacticalStrike.apk
```

If Gradle picks the wrong JVM, force it:
`./android/build/gradlew -Dorg.gradle.java.home=$JAVA_HOME ...`

## Regenerating the art

No binary art is authored by hand; every model, texture and sound is produced by
a rerunnable script from CC0 source packs or from pure procedural generation.

```sh
python3 tools/assets/build_all.py          # runs the whole asset pipeline
```

See [docs/ASSET_PIPELINE.md](docs/ASSET_PIPELINE.md) for the palette-atlas
technique, the naming/scale conventions and the in-engine verification workflow.
Licensing for every source pack is recorded in [CREDITS.md](CREDITS.md).

## Repository layout

```
project.godot            Godot project (GL Compatibility, mobile settings)
export_presets.cfg       Android export preset (arm64-v8a, Gradle build)
android/                 Godot's Android Gradle build template (pinned versions)
src/
  autoload/              Settings, GameState, Economy, Persistence, AudioMgr, Pools, InputHub
  characters/            CharacterBase, player, bots
  weapons/               weapon runtime, projectiles, grenades
  game/                  match/round flow, map interface
  ui/                    HUD, menus, touch controls
  data/                  weapon database, balance tables
scenes/                  scene files, grouped to mirror src/
assets/                  generated models, textures, audio
tools/                   build, preview and verification scripts
  assets/                the art pipeline (Blender + Pillow)
docs/                    architecture and pipeline contracts
```

## Verification tooling

```sh
# Load-check scenes
godot --headless --path . --script tools/check_scene.gd -- res://scenes/game/match.tscn

# Render a model on a studio set and print its triangle count
xvfb-run -a -s "-screen 0 1280x720x24" godot --rendering-driver opengl3 \
  --resolution 1280x720 --path . --script tools/preview_model.gd -- \
  res://assets/weapons/ar77/tp.glb /tmp/ar77.png 35

# Capture a scene after N frames
xvfb-run -a godot --rendering-driver opengl3 --path . \
  --script tools/screenshot.gd -- res://scenes/ui/main_menu.tscn /tmp/menu.png 30
```

## Licence

Game code is original. Art is derived from CC0 sources or generated
procedurally — see [CREDITS.md](CREDITS.md).
