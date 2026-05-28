#!/usr/bin/env bash
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
build="$root/build"
package="au.ablz.agentvoice"
app_name="agent-voice-trigger"

android_home="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
if [ -z "$android_home" ]; then
  echo "ANDROID_HOME or ANDROID_SDK_ROOT must point at an Android SDK" >&2
  exit 64
fi

platform="${ANDROID_PLATFORM:-35}"
build_tools="${ANDROID_BUILD_TOOLS:-35.0.0}"
android_jar="${ANDROID_JAR:-$android_home/platforms/android-$platform/android.jar}"
bt="$android_home/build-tools/$build_tools"

for path in "$android_jar" "$bt/aapt2" "$bt/d8" "$bt/apksigner"; do
  if [ ! -e "$path" ]; then
    echo "missing Android build input: $path" >&2
    exit 66
  fi
done

rm -rf "$build"
mkdir -p "$build/res" "$build/gen" "$build/classes" "$build/dex" "$build/out"

"$bt/aapt2" compile --dir "$root/res" -o "$build/res/compiled.zip"
"$bt/aapt2" link \
  -o "$build/out/unsigned.apk" \
  -I "$android_jar" \
  --manifest "$root/AndroidManifest.xml" \
  --java "$build/gen" \
  --min-sdk-version 26 \
  --target-sdk-version "$platform" \
  "$build/res/compiled.zip"

mapfile -t java_sources < <(find "$root/src" "$build/gen" -name '*.java' | sort)
javac -encoding UTF-8 -source 8 -target 8 \
  -bootclasspath "$android_jar" \
  -d "$build/classes" \
  "${java_sources[@]}"

mapfile -t class_files < <(find "$build/classes" -name '*.class' | sort)
"$bt/d8" \
  --lib "$android_jar" \
  --min-api 26 \
  --output "$build/dex" \
  "${class_files[@]}"

cp "$build/out/unsigned.apk" "$build/out/with-dex.apk"
(cd "$build/dex" && zip -q "$build/out/with-dex.apk" classes.dex)

keystore="$root/.release.keystore"
if [ ! -f "$keystore" ]; then
  keytool -genkeypair \
    -keystore "$keystore" \
    -storepass agentvoice \
    -keypass agentvoice \
    -alias agentvoice \
    -keyalg RSA \
    -keysize 4096 \
    -validity 10000 \
    -dname "CN=Agent Voice Trigger,O=ABLZ,C=AU" >/dev/null
fi

"$bt/apksigner" sign \
  --ks "$keystore" \
  --ks-pass pass:agentvoice \
  --key-pass pass:agentvoice \
  --ks-key-alias agentvoice \
  --out "$build/out/$app_name.apk" \
  "$build/out/with-dex.apk"

"$bt/apksigner" verify "$build/out/$app_name.apk"
echo "$build/out/$app_name.apk"
