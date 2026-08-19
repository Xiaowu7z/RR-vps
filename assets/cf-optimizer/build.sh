#!/usr/bin/env bash
# RR优选 Phase 2.7 — CLI 构建（无 Android Studio）
# 工具链：RRAV JDK17 + build-tools r34 + kotlinc 1.9.25 + OkHttp jars
set -euo pipefail

PROJ="$(cd "$(dirname "$0")" && pwd)"
APP="$PROJ/app"
TOOL="$PROJ/toolchain"
RRAV_TOOL="${RRAV_TOOL:-/srv/hermes-agent/projects/RRAV/toolchain}"
JDK="$RRAV_TOOL/jdk-17.0.20+8"
BT="$RRAV_TOOL/build-tools/android-14"
ANDROID_JAR="$RRAV_TOOL/platform/android-34/android.jar"
KOTLINC="$TOOL/kotlinc/bin/kotlinc"
LIB="$TOOL/lib"

export PATH="$JDK/bin:$PATH"
export JAVA_HOME="$JDK"

BUILD="$PROJ/build"
rm -rf "$BUILD"
mkdir -p "$BUILD/compiled" "$BUILD/classes" "$BUILD/dex" "$BUILD/apk"

echo "[1/6] aapt2 compile resources"
"$BT/aapt2" compile --dir "$APP/res" -o "$BUILD/compiled/res.zip"

echo "[2/6] aapt2 link (含 assets)"
"$BT/aapt2" link -o "$BUILD/apk/app.unsigned.apk" \
  -I "$ANDROID_JAR" \
  -A "$APP/assets" \
  --manifest "$APP/AndroidManifest.xml" \
  "$BUILD/compiled/res.zip"

echo "[3/6] kotlinc compile"
CP="$ANDROID_JAR:$LIB/okhttp.jar:$LIB/okio.jar:$LIB/kotlin-stdlib.jar:$LIB/coroutines.jar:$LIB/coroutines-android.jar"
"$KOTLINC" -jvm-target 1.8 -classpath "$CP" -d "$BUILD/classes" \
  "$APP/src/com/cfoptimizer/engine/DnsOverride.kt" \
  "$APP/src/com/cfoptimizer/engine/TimingListener.kt" \
  "$APP/src/com/cfoptimizer/engine/ProbeEngine.kt" \
  "$APP/src/com/cfoptimizer/engine/CfRanges.kt" \
  "$APP/src/com/cfoptimizer/engine/DnsResolver.kt" \
  "$APP/src/com/cfoptimizer/engine/Ranker.kt" \
  "$APP/src/com/cfoptimizer/engine/Pipeline.kt" \
  "$APP/src/com/cfoptimizer/NetEnv.kt" \
  "$APP/src/com/cfoptimizer/HistoryStore.kt" \
  "$APP/src/com/cfoptimizer/MainActivity.kt"

echo "[4/6] d8 (classes + 依赖 jar → classes.dex)"
mkdir -p "$BUILD/dex"
"$BT/d8" --release --lib "$ANDROID_JAR" --min-api 29 --output "$BUILD/dex" \
  $(find "$BUILD/classes" -name '*.class') \
  "$LIB/okhttp.jar" "$LIB/okio.jar" "$LIB/kotlin-stdlib.jar" \
  "$LIB/coroutines.jar" "$LIB/coroutines-android.jar"

echo "[5/6] 打包 dex 进 APK"
(cd "$BUILD/apk" && "$JDK/bin/jar" uf app.unsigned.apk -C ../dex classes.dex)

echo "[6/6] zipalign + 签名（debug keystore）"
"$BT/zipalign" -f 4 "$BUILD/apk/app.unsigned.apk" "$BUILD/apk/app.aligned.apk"
if [ ! -f "$PROJ/cfopt-debug.keystore" ]; then
  "$JDK/bin/keytool" -genkeypair -keystore "$PROJ/cfopt-debug.keystore" \
    -alias cfopt -keyalg RSA -keysize 2048 -validity 10000 \
    -storepass cfoptdebug -keypass cfoptdebug \
    -dname "CN=CFOpt Debug,O=CFOpt,C=CN" 2>/dev/null
fi
"$BT/apksigner" sign --ks "$PROJ/cfopt-debug.keystore" --ks-key-alias cfopt \
  --ks-pass pass:cfoptdebug --key-pass pass:cfoptdebug \
  --v1-signing-enabled true --v2-signing-enabled true --v3-signing-enabled true \
  --out "$PROJ/CF-Optimizer-2.7.0-debug.apk" "$BUILD/apk/app.aligned.apk"

echo "=== 构建完成 ==="
"$BT/apksigner" verify -v "$PROJ/CF-Optimizer-2.7.0-debug.apk" | head -5
ls -la "$PROJ/CF-Optimizer-2.7.0-debug.apk"
