#!/usr/bin/env bash
# 构建官方 arm64 演示包，并在项目路径含非 ASCII 字符时自动改用 ASCII 镜像目录。
#
# 为什么需要这个脚本（2026-11-16 实测，Windows）：
# 工作副本放在 `D:\明途AI\mingtu-ai` 时，`flutter build apk` 有两道坎：
#   1) AGP 直接拒绝非 ASCII 路径：
#      "Your project path contains non-ASCII characters."（1 秒即失败）
#   2) 用 junction 映射到 `D:\mingtu` 也没用 —— Gradle 会把路径解析回真实
#      路径；就算加 `android.overridePathCheck=true` 盖过第一道坎，Gradle 调
#      `flutter.bat` 时项目路径会按 GBK 解读成 `D:\��;AI\...`，接着报
#      "Unable to read file: ...app.dill"。
# 结论：非 ASCII 路径在本机无法直接出包，必须在纯 ASCII 目录里构建。
# 本脚本把工作副本镜像到 `$MINGTU_ASCII_MIRROR` 再构建，产物拷回原仓库，
# 这样源码位置不用动。CI/Linux 路径本来就是 ASCII，走直连分支，行为不变。
#
# 用法：
#   bash tool/build_release_apk.sh                      # 官方 arm64 演示包
#   bash tool/build_release_apk.sh --dart-define=K=V ... # 追加 Flutter 参数
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MIRROR="${MINGTU_ASCII_MIRROR:-/d/build/mingtu-ai}"
FLUTTER_BIN="${FLUTTER_BIN:-flutter}"

# 项目路径含非 ASCII 字符？（纯 ASCII 路径走直连分支）
is_ascii_path() {
  [ -z "$(printf '%s' "$1" | LC_ALL=C tr -d '\000-\177')" ]
}

build_in() {
  local dir="$1"
  shift  # 剩下的才是要透传给 flutter 的参数
  echo "==> 构建目录：$dir"
  ( cd "$dir" && "$FLUTTER_BIN" build apk --release --target-platform android-arm64 "$@" )
}

if is_ascii_path "$REPO_ROOT"; then
  build_in "$REPO_ROOT" "$@"
  APK="$REPO_ROOT/build/app/outputs/flutter-apk/app-release.apk"
else
  echo "!! 项目路径含非 ASCII 字符：$REPO_ROOT"
  echo "!! 按上面注释的原因，改为在 ASCII 镜像目录构建：$MIRROR"
  mkdir -p "$MIRROR"

  # 镜像工作副本（保留未提交改动），排除构建缓存与 .git。
  # robocopy 的退出码 0-7 都算成功（1 = 复制了新文件）。
  if command -v robocopy >/dev/null 2>&1; then
    set +e
    robocopy "$(cygpath -w "$REPO_ROOT")" "$(cygpath -w "$MIRROR")" /E /XD build .dart_tool .git .kotlin /NFL /NDL /NJH /NJS /NP
    rc=$?
    set -e
    [ "$rc" -lt 8 ] || { echo "robocopy 失败，exit=$rc"; exit 1; }
  else
    # 非 Windows 的兜底：rsync 优先
    command -v rsync >/dev/null 2>&1 || { echo "需要 robocopy 或 rsync 才能镜像目录"; exit 1; }
    rsync -a --delete \
      --exclude build --exclude .dart_tool --exclude .git --exclude .kotlin \
      "$REPO_ROOT"/ "$MIRROR"/
  fi

  build_in "$MIRROR" "$@"

  # 产物拷回原仓库，方便就地取包
  OUT="$REPO_ROOT/build/app/outputs/flutter-apk"
  mkdir -p "$OUT"
  cp "$MIRROR/build/app/outputs/flutter-apk/app-release.apk" "$OUT/app-release.apk"
  APK="$OUT/app-release.apk"
fi

echo
echo "==> 产物：$APK"
ls -l "$APK" | awk '{ printf "    体积：%.1f MB\n", $5/1024/1024 }'
if command -v sha256sum >/dev/null 2>&1; then
  echo "    SHA256：$(sha256sum "$APK" | cut -d' ' -f1)"
fi
