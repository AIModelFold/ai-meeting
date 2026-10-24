#!/bin/zsh
# 打包 AI Meeting.app（1.0 时叫「会议助手」）：编译启动面板 + 引擎（capture / translate / subtitle），拷入 run.mjs、qa.mjs、i18n.mjs，
# 识别模型默认不进包（安装包约 47MB）：App 打开后在后台下载（断点续传、进度条、下完系统通知）；最后签名，再打成 dmg（拖进 Applications 安装）。
# Bundle ID（online.modelfold.meeting-assistant）和签名证书不变：已经给过的「屏幕与系统录音」权限照样有效。
# 用法：app/build.sh [输出目录]
#   Apple 芯片版（默认，ARCH=arm64）：输出 app/dist/AI Meeting.app + AI-Meeting-<版本>-mac-arm64.dmg
#   Intel 版：ARCH=x86_64 app/build.sh → app/dist-intel/AI Meeting.app + AI-Meeting-<版本>-mac-intel.dmg
#   BUNDLE_MODEL=1：把识别模型打进包（Apple 芯片 large-v3-turbo 1.6GB / Intel small + base），dmg 名加 -with-model；
#     App 优先用包里的模型，不再下载
#   模型来源：MODEL_DIR > ~/Library/Application Support/AI Meeting/models > 旧版 会议助手/models > 项目 models/ > windows/.cache/models，
#     都没有就从 huggingface（不通走 hf-mirror，再不通走代理 DL_PROXY）下载
#   SKIP_DMG=1：只出 .app 不打 dmg（调试用）
#     Node 用官方 darwin-x64 二进制（与本机 node 同版本，SHASUMS256 校验），whisper-server 从源码交叉编译
#     （ggml 静态链接、纯 CPU + Accelerate，不带 Metal / libomp）；下载和编译结果缓存在 app/.cache-x86_64，需要 cmake
#     直连下载失败会走本机代理 DL_PROXY（默认 http://127.0.0.1:7897）
set -e
cd "$(dirname "$0")/.."
ARCH="${ARCH:-arm64}"
VERSION="${VERSION:-1.1}"
BUILD_NO="${BUILD_NO:-2}"
BUNDLE_MODEL="${BUNDLE_MODEL:-0}"
NAME="AI Meeting"
case "$ARCH" in
  # Apple 芯片版用本机（macOS 26）编译 + Homebrew 的 whisper-server（也是 26 编的），所以最低 macOS 26；Intel 版全按 15 编
  arm64)  OUT="${1:-$PWD/app/dist}";       DMG_NAME="AI-Meeting-$VERSION-mac-arm64.dmg"; VOLNAME="AI Meeting";        SWIFTFLAGS=(); MIN_OS=26.0
          MODEL_FILES=(ggml-large-v3-turbo.bin:1500000000) ;;
  x86_64) OUT="${1:-$PWD/app/dist-intel}"; DMG_NAME="AI-Meeting-$VERSION-mac-intel.dmg"; VOLNAME="AI Meeting (Intel)"; SWIFTFLAGS=(-target x86_64-apple-macos15); MIN_OS=15.0
          MODEL_FILES=(ggml-small-q5_1.bin:180000000 ggml-base-q5_1.bin:55000000) ;;
  *) echo "ARCH 只支持 arm64 / x86_64"; exit 1 ;;
esac
[ "$BUNDLE_MODEL" = 1 ] && DMG_NAME="${DMG_NAME%.dmg}-with-model.dmg"
APP="$OUT/$NAME.app"
E="$APP/Contents/Resources/engine"

fetch() {  # fetch <url> <保存到>：先直连，不通再走代理
  curl -fSL --retry 2 --connect-timeout 15 -o "$2" "$1" ||
    curl -fSL --retry 2 --connect-timeout 15 -x "${DL_PROXY:-http://127.0.0.1:7897}" -o "$2" "$1"
}

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$E"
swiftc -O "${SWIFTFLAGS[@]}" app/MeetingAssistant.swift -o "$APP/Contents/MacOS/$NAME"
for b in capture translate subtitle; do swiftc -O "${SWIFTFLAGS[@]}" $b.swift -o "$E/$b"; done
cp run.mjs qa.mjs i18n.mjs core.mjs "$E/"

# ---- 自带运行环境：Node + whisper-server（含 ggml / libomp 动态库），别的 Mac 不用再 brew 安装 ----
if [ "$ARCH" = x86_64 ]; then
  CACHE="$PWD/app/.cache-x86_64"
  mkdir -p "$CACHE/dl" "$CACHE/src"
  # Node：官方 darwin-x64，版本默认跟本机 node（也就是 Apple 芯片版自带的那个）一致
  NODE_VERSION="${NODE_VERSION:-$(node -v)}"
  NODE_DIR="$CACHE/node-$NODE_VERSION-darwin-x64"
  if [ ! -x "$NODE_DIR/bin/node" ]; then
    T="node-$NODE_VERSION-darwin-x64.tar.gz"
    fetch "https://nodejs.org/dist/$NODE_VERSION/SHASUMS256.txt" "$CACHE/dl/SHASUMS256-$NODE_VERSION.txt"
    fetch "https://nodejs.org/dist/$NODE_VERSION/$T" "$CACHE/dl/$T"
    want=$(awk -v f="$T" '$2 == f {print $1}' "$CACHE/dl/SHASUMS256-$NODE_VERSION.txt")
    got=$(shasum -a 256 "$CACHE/dl/$T" | awk '{print $1}')
    if [ -z "$want" ] || [ "$want" != "$got" ]; then echo "Node 安装包 SHA256 校验失败：$T"; rm -f "$CACHE/dl/$T"; exit 1; fi
    echo "Node $NODE_VERSION darwin-x64 SHA256 校验通过"
    tar -xzf "$CACHE/dl/$T" -C "$CACHE"
  fi
  cp "$NODE_DIR/bin/node" "$E/node"                 # 官方二进制，保留原签名（带 JIT 授权），不改它
  # whisper-server：源码版本默认跟 Homebrew 的 whisper-cpp（Apple 芯片版自带的）一致
  WHISPER_VERSION="${WHISPER_VERSION:-$(brew list --versions whisper-cpp 2>/dev/null | awk '{print $2}')}"
  WHISPER_VERSION="${WHISPER_VERSION:-1.9.5}"
  WSRC="$CACHE/src/whisper.cpp-$WHISPER_VERSION"
  WBUILD="$CACHE/build-whisper-$WHISPER_VERSION"
  if [ ! -x "$WBUILD/bin/whisper-server" ]; then
    command -v cmake >/dev/null || { echo "编译 Intel 版 whisper-server 需要 cmake：brew install cmake"; exit 1; }
    if [ ! -d "$WSRC" ]; then
      fetch "https://github.com/ggml-org/whisper.cpp/archive/refs/tags/v$WHISPER_VERSION.tar.gz" "$CACHE/dl/whisper.cpp-$WHISPER_VERSION.tar.gz"
      tar -xzf "$CACHE/dl/whisper.cpp-$WHISPER_VERSION.tar.gz" -C "$CACHE/src"
    fi
    # 指令集定在 AVX2 + FMA + F16C（macOS 15 支持的 Intel Mac 都有），不用 -march=native（编译机是 Apple 芯片）
    cmake -S "$WSRC" -B "$WBUILD" -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_OSX_ARCHITECTURES=x86_64 -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0 \
      -DBUILD_SHARED_LIBS=OFF -DGGML_NATIVE=OFF -DGGML_SSE42=ON -DGGML_AVX=ON -DGGML_AVX2=ON -DGGML_FMA=ON -DGGML_F16C=ON -DGGML_BMI2=ON \
      -DGGML_METAL=OFF -DGGML_OPENMP=OFF -DGGML_BLAS=ON -DGGML_CCACHE=OFF \
      -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_EXAMPLES=ON -DWHISPER_BUILD_SERVER=ON > "$CACHE/whisper-build.log" 2>&1 &&
    cmake --build "$WBUILD" --config Release -j "$(sysctl -n hw.ncpu)" --target whisper-server >> "$CACHE/whisper-build.log" 2>&1 ||
      { tail -30 "$CACHE/whisper-build.log"; echo "whisper-server 编译失败，完整日志：$CACHE/whisper-build.log"; exit 1; }
    echo "whisper-server $WHISPER_VERSION（x86_64）编译完成"
  fi
  W="$E/whisper"; mkdir -p "$W"
  cp "$WBUILD/bin/whisper-server" "$W/whisper-server"   # 静态链接，只依赖系统库（libSystem / libc++ / Accelerate）
  chmod u+w "$W"/*
else
NODE_SRC="${NODE_SRC:-$(command -v node)}"
cp "$(readlink -f "$NODE_SRC")" "$E/node"          # Node 官方二进制，保留原签名（带 JIT 授权），不改它
W="$E/whisper"; mkdir -p "$W"
WS=$(readlink -f "$(command -v whisper-server)")
WLIB=$(dirname "$WS")/../lib
GGML=$(brew --prefix ggml); OMP=$(brew --prefix libomp)
cp "$WS" "$W/whisper-server"
cp "$(readlink -f "$WLIB/libwhisper.1.dylib")" "$W/libwhisper.1.dylib"
cp "$(readlink -f "$GGML/lib/libggml.0.dylib")" "$W/libggml.0.dylib"
cp "$(readlink -f "$GGML/lib/libggml-base.0.dylib")" "$W/libggml-base.0.dylib"
cp "$(readlink -f "$OMP/lib/libomp.dylib")" "$W/libomp.dylib"
cp "$GGML"/libexec/libggml-*.so "$W/"           # 计算后端（Metal / 各代 Apple 芯片 CPU / BLAS），ggml 从可执行文件同目录加载
chmod u+w "$W"/*
fi
for f in "$W"/*; do
  # 所有 Homebrew 绝对路径 / @rpath 依赖改成同目录
  for dep in $(otool -L "$f" | tail -n +2 | awk '{print $1}' | grep -E '^(/opt/homebrew|/usr/local|@rpath)'); do
    install_name_tool -change "$dep" "@loader_path/$(basename "$dep")" "$f" 2>/dev/null
  done
  case "$f" in *.dylib) install_name_tool -id "@loader_path/$(basename "$f")" "$f";; esac
done
[ -f app/AppIcon.icns ] && cp app/AppIcon.icns "$APP/Contents/Resources/"

# ---- 识别模型进包（只有 BUNDLE_MODEL=1 时）：App 优先用包里的，缺了才用 Application Support / 后台下载 ----
if [ "$BUNDLE_MODEL" = 1 ]; then
  M="$APP/Contents/Resources/models"; mkdir -p "$M"
  SUP="$HOME/Library/Application Support"
  for spec in "${MODEL_FILES[@]}"; do
    f="${spec%%:*}"; min="${spec##*:}"; src=""
    for d in "${MODEL_DIR:-}" "$SUP/AI Meeting/models" "$SUP/会议助手/models" "$PWD/models" "$PWD/windows/.cache/models"; do
      [ -n "$d" ] && [ -f "$d/$f" ] && [ "$(stat -f %z "$d/$f")" -ge "$min" ] && { src="$d/$f"; break; }
    done
    if [ -z "$src" ]; then
      mkdir -p "$PWD/models"; tmp="$PWD/models/$f.part"
      fetch "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/$f" "$tmp" ||
        fetch "https://hf-mirror.com/ggerganov/whisper.cpp/resolve/main/$f" "$tmp" || { echo "识别模型下载失败：$f"; exit 1; }
      [ "$(stat -f %z "$tmp")" -ge "$min" ] || { echo "识别模型不完整：$f"; rm -f "$tmp"; exit 1; }
      mv "$tmp" "$PWD/models/$f"; src="$PWD/models/$f"
    fi
    cp -c "$src" "$M/$f" 2>/dev/null || cp "$src" "$M/$f"   # APFS 上是克隆，不多占空间
    echo "识别模型进包：$f（$(( $(stat -f %z "$M/$f") / 1000000 ))MB，来自 $src）"
  done
fi

# 系统弹窗 / Finder 里的文字：英文为主，中文系统显示中文
for l in en zh-Hans; do mkdir -p "$APP/Contents/Resources/$l.lproj"; done
cat > "$APP/Contents/Resources/en.lproj/InfoPlist.strings" <<'STR'
"CFBundleDisplayName" = "AI Meeting";
"NSScreenCaptureUsageDescription" = "AI Meeting records the sound your Mac plays to make live captions.";
"NSMicrophoneUsageDescription" = "AI Meeting records your microphone so your own words appear in the captions and notes (labeled Me) and AI answers can build on them.";
STR
cat > "$APP/Contents/Resources/zh-Hans.lproj/InfoPlist.strings" <<'STR'
"CFBundleDisplayName" = "AI Meeting";
"NSScreenCaptureUsageDescription" = "AI Meeting 需要录制系统声音，用于生成实时字幕。";
"NSMicrophoneUsageDescription" = "AI Meeting 需要使用麦克风，把你自己说的话也记进字幕和会议记录（标为「我」），AI 回答会接着你说过的内容。";
STR

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundleDisplayName</key><string>$NAME</string>
  <key>CFBundleIdentifier</key><string>online.modelfold.meeting-assistant</string>
  <key>CFBundleExecutable</key><string>$NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NO</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key><array><string>en</string><string>zh-Hans</string></array>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>$MIN_OS</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSScreenCaptureUsageDescription</key><string>AI Meeting records the sound your Mac plays to make live captions.</string>
  <key>NSMicrophoneUsageDescription</key><string>AI Meeting records your microphone so your own words appear in the captions and notes (labeled Me) and AI answers can build on them.</string>
</dict></plist>
PLIST

# 签名：有本机固定签名证书就用它（屏幕录制权限认「标识 + 证书」，重新打包不用再授权），没有就 ad-hoc（每次打包都要重新授权）
# Set SIGN_IDENTITY to your own signing certificate, or use ad-hoc signing.
SIGN=(-s "${SIGN_IDENTITY:--}")
for b in capture translate subtitle; do codesign --force "${SIGN[@]}" -i online.modelfold.meeting-assistant.$b "$E/$b"; done
for f in "$W"/*; do codesign --force "${SIGN[@]}" "$f"; done
codesign --force "${SIGN[@]}" "$APP"

# 架构检查：包里每个可执行文件 / 动态库都必须只含 $ARCH
BAD=0
while IFS= read -r f; do
  file -b "$f" | grep -q '^Mach-O' || continue
  a=$(lipo -archs "$f")
  [ "$a" = "$ARCH" ] || { echo "架构不对（$a）：$f"; BAD=1; }
done < <(find "$APP" -type f)
[ $BAD = 0 ] || exit 1
echo "架构检查通过：全部 $ARCH"

codesign --verify --deep --strict "$APP" && echo "签名校验通过"
echo "已生成：$APP（$(du -sh "$APP" | awk '{print $1}')）"
[ "${SKIP_DMG:-0}" = 1 ] && exit 0

# dmg：AI Meeting.app + Applications 快捷方式（lzfse 压缩，macOS 10.11+ 都能打开）
STAGE=$(mktemp -d)
cp -cR "$APP" "$STAGE/" 2>/dev/null || cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$OUT/$DMG_NAME"
hdiutil create -volname "$VOLNAME" -srcfolder "$STAGE" -ov -format ULFO "$OUT/$DMG_NAME" >/dev/null
rm -rf "$STAGE"
echo "安装包：$OUT/$DMG_NAME（$(du -h "$OUT/$DMG_NAME" | awk '{print $1}')）"
