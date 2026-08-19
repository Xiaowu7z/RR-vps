#!/usr/bin/env bash
set -euo pipefail

BRANCH="cfopt-2.7.1-release"
CERT_FP="559b45af093084abb7850703bac7f851bb8c20ab95cc9ff41010fd7ea10b5f07"

# A second PR run is expected after this runner publishes its one-time public key.
# Only the runner that created the key is allowed to continue and hold the private half.
git fetch origin "$BRANCH" --quiet
if git cat-file -e "origin/$BRANCH:tmp/cfopt-exchange-public.pem" 2>/dev/null; then
  echo "A release runner is already active; this duplicate run exits cleanly."
  exit 0
fi

# One-time RSA transport key. The private half never leaves this runner.
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out /tmp/cfopt-exchange-private.pem >/dev/null 2>&1
openssl pkey -in /tmp/cfopt-exchange-private.pem -pubout -out tmp/cfopt-exchange-public.pem

git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
git add tmp/cfopt-exchange-public.pem
git commit -m "ci(cf-optimizer): publish one-time signing exchange key"
git push origin "HEAD:$BRANCH"

# Wait for ChatGPT to encrypt the established cfopt keystore to the public key above.
found=0
for i in $(seq 1 180); do
  git fetch origin "$BRANCH" --quiet
  if git show "origin/$BRANCH:tmp/cfopt-keystore.enc.b64" >/tmp/cfopt-keystore.enc.b64 2>/dev/null \
    && git show "origin/$BRANCH:tmp/cfopt-envelope.b64" >/tmp/cfopt-envelope.b64 2>/dev/null; then
    found=1
    break
  fi
  sleep 5
done
test "$found" = 1

# Decrypt the signing key only in runner /tmp and verify the pinned certificate fingerprint.
base64 -d /tmp/cfopt-envelope.b64 > /tmp/cfopt-envelope.bin
openssl pkeyutl -decrypt \
  -inkey /tmp/cfopt-exchange-private.pem \
  -in /tmp/cfopt-envelope.bin \
  -pkeyopt rsa_padding_mode:oaep \
  -pkeyopt rsa_oaep_md:sha256 \
  -out /tmp/cfopt-keyinfo.txt
KEYHEX=$(sed -n '1p' /tmp/cfopt-keyinfo.txt)
IVHEX=$(sed -n '2p' /tmp/cfopt-keyinfo.txt)
test ${#KEYHEX} -eq 64
test ${#IVHEX} -eq 32
base64 -d /tmp/cfopt-keystore.enc.b64 > /tmp/cfopt-keystore.enc
openssl enc -d -aes-256-cbc -K "$KEYHEX" -iv "$IVHEX" \
  -in /tmp/cfopt-keystore.enc -out /tmp/cfopt-debug.keystore
keytool -list -v -keystore /tmp/cfopt-debug.keystore -storepass cfoptdebug -alias cfopt \
  | tr -d ':' | grep -i "$CERT_FP"
rm -f /tmp/cfopt-keyinfo.txt /tmp/cfopt-envelope.bin /tmp/cfopt-keystore.enc

# Sync branch after the encrypted handoff commits.
git reset --hard "origin/$BRANCH"

# Reconstruct the previously validated 2.7.0 source base.
SRC_REF="414e667323bbfa64866defe5bec49c4e54bbd100"
BASE="https://raw.githubusercontent.com/Xiaowu7z/mhr-cfw/$SRC_REF"
rm -rf /tmp/cf271 /tmp/payload /tmp/source.b64 /tmp/source.tar.gz
mkdir -p /tmp/cf271 /tmp/payload
curl -fsSL "$BASE/tmp-cfopt270v2/payload_000.b64" -o /tmp/payload/000.b64
curl -fsSL "$BASE/tmp-cfopt270v2/payload_001.b64" -o /tmp/payload/001.b64
curl -fsSL "$BASE/tmp-cfopt270v3/payload_004.b64" -o /tmp/payload/004a.b64
curl -fsSL "$BASE/tmp-cfopt270v3/payload_005.b64" -o /tmp/payload/005a.b64
curl -fsSL "$BASE/tmp-cfopt270v2/payload_003.b64" -o /tmp/payload/003.b64
curl -fsSL "$BASE/tmp-cfopt270v2/payload_004.b64" -o /tmp/payload/004.b64
head -c 16000 /tmp/payload/000.b64 > /tmp/source.b64
cat /tmp/payload/001.b64 /tmp/payload/004a.b64 /tmp/payload/005a.b64 /tmp/payload/003.b64 /tmp/payload/004.b64 >> /tmp/source.b64
base64 -d /tmp/source.b64 > /tmp/source.tar.gz
echo "9e335876b4d3bd99f6696b7114ae3b94db8328144bde14420c35962a1e78b6b1  /tmp/source.tar.gz" | sha256sum -c -
tar -xzf /tmp/source.tar.gz -C /tmp/cf271

# Apply the validated 2.7.1 homepage ScrollView hotfix and Java/Kotlin 17 build compatibility.
python3 - <<'PY'
from pathlib import Path
root=Path('/tmp/cf271')

p=root/'app/build.gradle.kts'
s=p.read_text()
anchor='''    sourceSets["main"].apply {\n        manifest.srcFile("AndroidManifest.xml")\n'''
block='''    compileOptions {\n        sourceCompatibility = JavaVersion.VERSION_17\n        targetCompatibility = JavaVersion.VERSION_17\n    }\n    kotlinOptions {\n        jvmTarget = "17"\n    }\n\n'''
if 'sourceCompatibility = JavaVersion.VERSION_17' not in s:
    if anchor not in s:
        raise SystemExit('Gradle sourceSets anchor not found')
    p.write_text(s.replace(anchor, block+anchor))

manifest=root/'app/AndroidManifest.xml'
ms=manifest.read_text()
ms=ms.replace('android:versionCode="20"','android:versionCode="21"')
ms=ms.replace('android:versionName="2.7.0"','android:versionName="2.7.1"')
manifest.write_text(ms)

main=root/'app/src/com/cfoptimizer/MainActivity.kt'
ks=main.read_text()
old='''        homeView = root\n    }\n\n    // ================= 测速页 ================='''
new='''        val homeScroll = ScrollView(this).apply {\n            isFillViewport = true\n            isVerticalScrollBarEnabled = true\n            overScrollMode = View.OVER_SCROLL_IF_CONTENT_SCROLLS\n            setBackgroundColor(C_BG)\n            addView(root, android.view.ViewGroup.LayoutParams(\n                android.view.ViewGroup.LayoutParams.MATCH_PARENT,\n                android.view.ViewGroup.LayoutParams.WRAP_CONTENT\n            ))\n        }\n        homeView = homeScroll\n    }\n\n    // ================= 测速页 ================='''
if old not in ks:
    raise SystemExit('homeView anchor not found')
main.write_text(ks.replace(old,new,1))

build=root/'build.sh'
if build.exists():
    bs=build.read_text().replace('CF-Optimizer-2.6.0-debug.apk','CF-Optimizer-2.7.1.apk')
    build.write_text(bs)
PY

# Build the 1000-domain candidate pool used by 2.7.1.
curl -fsSL --retry 3 https://raw.githubusercontent.com/Danialsamadi/cf-knife/main/domains.txt -o /tmp/public-domains.txt
python3 - <<'PY'
from pathlib import Path
import re
root=Path('/tmp/cf271')
original=(root/'app/assets/domains.txt').read_text(encoding='utf-8',errors='ignore').splitlines()
public=Path('/tmp/public-domains.txt').read_text(encoding='utf-8',errors='ignore').splitlines()
deny=re.compile(r'(porn|xhamster|spank|stripchat|faphouse|onlyfans|sexcam|adult|casino|gambl|bet365|\.bet$|betano)',re.I)
valid=re.compile(r'^(?=.{1,253}$)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$',re.I)
out=[]; seen=set()
for raw in ['www.nexusmods.com','nexusmods.com',*original,*public]:
    d=raw.strip().lower().rstrip('.')
    if not d or d.startswith('#') or d in seen or deny.search(d) or not valid.match(d):
        continue
    seen.add(d); out.append(d)
    if len(out)>=1000:
        break
assert len(out)==1000
assert 'www.nexusmods.com' in seen
data='\n'.join(out)+'\n'
(root/'app/assets/domains.txt').write_text(data,encoding='utf-8')
(root/'domains.txt').write_text(data,encoding='utf-8')
PY

# Install build prerequisites on the GitHub runner.
if ! command -v gradle >/dev/null 2>&1; then
  wget -q https://services.gradle.org/distributions/gradle-8.10.2-bin.zip -O /tmp/gradle.zip
  unzip -q /tmp/gradle.zip -d /tmp
  export PATH="/tmp/gradle-8.10.2/bin:$PATH"
fi
if [ -z "${ANDROID_HOME:-}" ]; then
  export ANDROID_HOME="$HOME/android-sdk"
fi
export PATH="$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/platform-tools:$PATH"
if ! command -v sdkmanager >/dev/null 2>&1; then
  mkdir -p "$ANDROID_HOME/cmdline-tools"
  curl -fsSL https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip -o /tmp/android-tools.zip
  unzip -q /tmp/android-tools.zip -d /tmp/android-cmd
  mkdir -p "$ANDROID_HOME/cmdline-tools/latest"
  cp -a /tmp/android-cmd/cmdline-tools/. "$ANDROID_HOME/cmdline-tools/latest/"
  export PATH="$ANDROID_HOME/cmdline-tools/latest/bin:$PATH"
fi
yes | sdkmanager --licenses >/dev/null || true
sdkmanager "platforms;android-34" "build-tools;34.0.0" >/dev/null

# Build and re-sign using the established cfopt certificate.
cd /tmp/cf271
gradle :app:assembleDebug --no-daemon --console=plain
IN=/tmp/cf271/app/build/outputs/apk/debug/app-debug.apk
OUT=/tmp/CF-Optimizer-2.7.1.apk
"$ANDROID_HOME/build-tools/34.0.0/apksigner" sign \
  --ks /tmp/cfopt-debug.keystore --ks-key-alias cfopt \
  --ks-pass pass:cfoptdebug --key-pass pass:cfoptdebug \
  --v1-signing-enabled true --v2-signing-enabled true --v3-signing-enabled true \
  --out "$OUT" "$IN"
"$ANDROID_HOME/build-tools/34.0.0/apksigner" verify --verbose --print-certs "$OUT" | tee /tmp/apk-verify.txt
tr -d ':' </tmp/apk-verify.txt | grep -qi "$CERT_FP"
unzip -t "$OUT" >/dev/null

# Publish only the companion-tool area and the matching README block.
cd "$GITHUB_WORKSPACE"
rm -rf assets/cf-optimizer/app assets/cf-optimizer/test
mkdir -p assets/cf-optimizer
cp -a /tmp/cf271/app assets/cf-optimizer/
cp -a /tmp/cf271/test assets/cf-optimizer/
cp /tmp/cf271/build.sh assets/cf-optimizer/build.sh
cp /tmp/cf271/domains.txt assets/cf-optimizer/domains.txt
cp /tmp/cf271/build.gradle.kts assets/cf-optimizer/build.gradle.kts
cp /tmp/cf271/settings.gradle.kts assets/cf-optimizer/settings.gradle.kts
cp "$OUT" assets/cf-optimizer/CF-Optimizer-2.7.1.apk
find assets/cf-optimizer -type d -name build -prune -exec rm -rf {} +
rm -rf assets/cf-optimizer/.gradle
APK_SHA=$(sha256sum assets/cf-optimizer/CF-Optimizer-2.7.1.apk | awk '{print $1}')

cat > assets/cf-optimizer/README.md <<EOF
# CF 域名优选（Android）

Cloudflare IP / 域名入口优选 Android 工具。原生 Kotlin，仅申请联网与网络状态权限，无广告。

## 当前版本

**2.7.1**（\`CF-Optimizer-2.7.1.apk\`，SHA-256：\`$APK_SHA\`）

- 包名：\`com.cfoptimizer\`，versionCode 21，minSdk 29，targetSdk 34
- IPv4 / IPv6 / 双栈独立测速
- 均衡模式 + **亚洲入口狩猎**模式
- 亚洲入口优先级：HKG > NRT > SIN > ICN > TPE；Full 阶段再次 trace 检查 POP 漂移
- 1000 个候选域名种子，DNS 去重 Cloudflare IP，按 IP / POP / Prefix 发现入口
- Nexus Mods 固定基准、Final Address Floor、失败计 0、成功率/波动/TTFB/最佳与最差 IP
- 50 条历史记录；2.7.1 修复主页内容超出屏幕后无法向下滚动、历史记录入口无法点击的问题

历史 APK：\`CF-Optimizer-2.6.0-debug.apk\`、\`CF-Optimizer-2.5.0-debug.apk\`。

## 目录

- \`app/\` — Android 工程源码
- \`test/\` — 测试源码
- \`domains.txt\` — 1000 域名候选池
- \`build.gradle.kts\` / \`settings.gradle.kts\` — Gradle 构建入口
- \`build.sh\` — CLI 构建脚本

## 构建

标准 Gradle 环境可使用 JDK 17 + Android SDK 34 + Gradle 8.10.2 构建。
EOF

python3 - <<'PY'
from pathlib import Path
p=Path('README.md')
s=p.read_text()
start=s.index('## 配套工具：CF 域名优选（Android）')
end=s.index('## 主要功能', start)
block='''## 配套工具：CF 域名优选（Android）

Cloudflare IP 优选 Android 工具，为节点订阅挑选更合适的 Cloudflare IP + 域名入口组合。原生 Kotlin，权限最小化（仅联网与网络状态），无广告。

- 最新版 **2.7.1** APK 下载：[assets/cf-optimizer/CF-Optimizer-2.7.1.apk](assets/cf-optimizer/CF-Optimizer-2.7.1.apk)（2.6.0 / 2.5.0 继续保留存档）
- 完整源码：[assets/cf-optimizer/](assets/cf-optimizer/)（`app/` 工程源码 + `test/` 测试 + Gradle/CLI 构建文件 + **1000 域名候选池**）
- 模式：均衡测速 + **亚洲入口狩猎**；亚洲入口优先 HKG > NRT > SIN > ICN > TPE，并在 Full 阶段复验 POP 漂移
- 功能：IPv4/IPv6/双栈独立管线、Cloudflare IP/POP/Prefix 发现、Nexus 基准守擂、Final Address Floor、TTFB/成功率/波动、50 条历史记录
- 2.7.1：修复主页无法向下滚动导致“历史测试”入口不可达
- 详情见 [assets/cf-optimizer/README.md](assets/cf-optimizer/README.md)

'''
p.write_text(s[:start]+block+s[end:])
PY

# Remove all one-time transport/build orchestration files before the release commit.
rm -f assets/cf-optimizer/.release-trigger
rm -f tmp/cfopt-exchange-public.pem tmp/cfopt-keystore.enc.b64 tmp/cfopt-envelope.b64 tmp/cfopt-release.sh
rm -f .github/workflows/cfopt-2.7.1-release-temp.yml

git add -A README.md assets/cf-optimizer tmp .github/workflows/cfopt-2.7.1-release-temp.yml || true
echo "Final changed paths:"
git diff --cached --name-only
BAD=$(git diff --cached --name-only | grep -Ev '^(README\.md|assets/cf-optimizer/|\.github/workflows/cfopt-2\.7\.1-release-temp\.yml$|tmp/cfopt-(release\.sh|exchange-public\.pem|keystore\.enc\.b64|envelope\.b64)$)' || true)
test -z "$BAD"
git commit -m "release(cf-optimizer): 2.7.1 Asia entry hunt"
git push origin "HEAD:$BRANCH"

# Private material is never committed and is wiped at the end of the runner.
rm -f /tmp/cfopt-debug.keystore /tmp/cfopt-exchange-private.pem /tmp/cfopt-keystore.enc.b64 /tmp/cfopt-envelope.b64
