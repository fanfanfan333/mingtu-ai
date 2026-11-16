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
# ============================================================================
# 编译期配置注入（2026-11-16）
# ----------------------------------------------------------------------------
# 为什么要有这一段：`lib/config/app_config.dart` 里的路线/识图配置全部是
# `String.fromEnvironment(...)` 编译期常量，只能靠 `--dart-define` 注入。
# 之前本脚本只把参数原样透传，既没有注入也没有校验，于是产出过「能装能启动、
# 但一进导航就播报『路线不可用』」的演示包 —— 缺陷在手机上才被发现。
# 现在把这件事搬到构建期：
#   1) 自动读取 `tool/release_defines.local.env`（已被 .gitignore 忽略，
#      格式 KEY=VALUE，一行一个，# 开头为注释），转成 --dart-define；
#   2) 同名环境变量覆盖文件里的值；命令行显式 --dart-define 优先级最高；
#   3) 构建后从 APK 解出 lib/arm64-v8a/libapp.so，逐项字节校验每个注入的
#      「值」确实进了包，缺一项就 exit 1（这是脚本自身坏了，必须失败）；
#   4) `MINGTU_AMAP_KEY` 与 `MINGTU_ROUTE_PROXY_URL` 都为空时显式告警并在
#      APK 同目录写 `*.NOTICE.txt`；加 `--require-routes` 则直接 exit 1。
# 优先级（低 → 高）：本地配置文件 < 同名环境变量 < 命令行 --dart-define。
# 密钥安全：任何情况下只打印 KEY 名，绝不回显值；本地配置文件不进 git，
# 也不复制进 ASCII 镜像目录。
#
# 用法：
#   bash tool/build_release_apk.sh                        # 官方 arm64 演示包
#   bash tool/build_release_apk.sh --require-routes       # 正式交付：缺路线配置即失败
#   MINGTU_AMAP_KEY=xxx bash tool/build_release_apk.sh    # 用环境变量注入
#   bash tool/build_release_apk.sh --dart-define=K=V ...  # 追加 Flutter 参数（优先级最高）
#
# 依赖：bash 4.2+（关联数组）、python3（校验 libapp.so 内的配置字节）。
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MIRROR="${MINGTU_ASCII_MIRROR:-/d/build/mingtu-ai}"
FLUTTER_BIN="${FLUTTER_BIN:-flutter}"
LOCAL_ENV_FILE="${MINGTU_RELEASE_DEFINES_FILE:-$REPO_ROOT/tool/release_defines.local.env}"

# 决定「这个包能不能真演示导航」的两个关键配置：两者都空 = 路线不可用。
ROUTE_KEYS=(MINGTU_AMAP_KEY MINGTU_ROUTE_PROXY_URL)
# 文档化的 5 个配置项：即使没有本地配置文件，也支持用环境变量注入。
DOC_KEYS=(
  MINGTU_AMAP_KEY
  MINGTU_ROUTE_PROXY_URL
  MINGTU_VISION_PROXY_URL
  MINGTU_VISION_TOKEN
  MINGTU_ASR_PROXY_URL
)

declare -A DEFINE_VALUE=()   # KEY -> 值
declare -A DEFINE_SOURCE=()  # KEY -> 值来源（仅用于打印，不含值）
declare -A DEFINE_EXPLICIT=() # KEY -> 命令行已显式指定（不再重复追加）
KEYS_ORDER=()
TMP_FILES=()

# 为什么这里的 rm 必须「失败不致命」：
# mktemp 在 Git Bash 下会返回 Windows 风格路径（D:/Temp/tmp.XXX），而本机宿主
# 对 rm 有 safe-delete 包装——它把这个绝对路径当成**相对当前目录**解析成
# d:\明途AI\mingtu-ai\D:\Temp\tmp.XXX，trash 失败后 fail-closed，rm 返回非 0。
# 在 set -euo pipefail 下，一个临时文件没删掉就会当场打死脚本：退出码变 1，
# 更要命的是第 8 步「缺路线配置写 NOTICE」因此被跳过，告警机制恰好失效。
cleanup() {
  local f
  for f in ${TMP_FILES[@]+"${TMP_FILES[@]}"}; do
    if [ -n "$f" ]; then
      rm -f "$f" 2>/dev/null || true
    fi
  done
}
trap cleanup EXIT

# 去掉首尾空白（纯 bash，避免 sed 的引号坑）。
trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# 登记一个 KEY（保持首次出现顺序，去重）。
add_key() {
  local k="$1" existing
  for existing in ${KEYS_ORDER[@]+"${KEYS_ORDER[@]}"}; do
    if [ "$existing" = "$k" ]; then
      return 0
    fi
  done
  KEYS_ORDER+=("$k")
}

# 设置一个配置值：$1=KEY $2=值 $3=来源描述 $4=1 表示命令行显式指定。
set_define() {
  local k="$1" v="$2" src="$3" explicit="${4:-0}"
  add_key "$k"
  DEFINE_VALUE["$k"]="$v"
  DEFINE_SOURCE["$k"]="$src"
  if [ "$explicit" = "1" ]; then
    DEFINE_EXPLICIT["$k"]=1
  fi
  return 0
}

# ---------------------------------------------------------------------------
# 1) 解析命令行：摘出 --require-routes，其余原样透传给 flutter。
# ---------------------------------------------------------------------------
REQUIRE_ROUTES=0
FLUTTER_ARGS=()
expect_define_operand=0
for arg in "$@"; do
  if [ "$expect_define_operand" = "1" ]; then
    # `--dart-define K=V` 两段式写法
    expect_define_operand=0
    FLUTTER_ARGS+=("$arg")
    case "$arg" in
      *=*) set_define "${arg%%=*}" "${arg#*=}" "命令行 --dart-define" 1 ;;
      *) echo "!! 忽略格式错误的参数：--dart-define $arg（应为 KEY=VALUE）" ;;
    esac
    continue
  fi
  case "$arg" in
    --require-routes)
      REQUIRE_ROUTES=1
      ;;
    --dart-define=*)
      FLUTTER_ARGS+=("$arg")
      kv="${arg#--dart-define=}"
      case "$kv" in
        *=*) set_define "${kv%%=*}" "${kv#*=}" "命令行 --dart-define" 1 ;;
        *) echo "!! 忽略格式错误的参数：--dart-define=$kv（应为 KEY=VALUE）" ;;
      esac
      ;;
    --dart-define)
      FLUTTER_ARGS+=("$arg")
      expect_define_operand=1
      ;;
    *)
      FLUTTER_ARGS+=("$arg")
      ;;
  esac
done

for doc_key in "${DOC_KEYS[@]}"; do
  add_key "$doc_key"
done

# ---------------------------------------------------------------------------
# 2) 读本地配置文件（最低优先级；文件不存在也能正常构建）。
# ---------------------------------------------------------------------------
echo "==> 本地配置：$LOCAL_ENV_FILE"
if [ -f "$LOCAL_ENV_FILE" ]; then
  line_no=0
  while IFS= read -r raw_line || [ -n "$raw_line" ]; do
    line_no=$((line_no + 1))
    line="${raw_line%$'\r'}"           # 容忍 CRLF
    line="$(trim "$line")"
    if [ -z "$line" ]; then
      continue
    fi
    case "$line" in
      \#*) continue ;;                  # 注释
      export\ *) line="$(trim "${line#export }")" ;;
    esac
    case "$line" in
      *=*) : ;;
      *)
        echo "!! $LOCAL_ENV_FILE:$line_no 不是 KEY=VALUE，已跳过"
        continue
        ;;
    esac
    key="$(trim "${line%%=*}")"
    value="${line#*=}"
    value="$(trim "$value")"
    # 去掉成对的引号（允许 KEY="VALUE" 这种写法）
    case "$value" in
      \"*\") value="${value#\"}"; value="${value%\"}" ;;
      \'*\') value="${value#\'}"; value="${value%\'}" ;;
    esac
    case "$key" in
      ''|*[!A-Za-z0-9_]*)
        echo "!! $LOCAL_ENV_FILE:$line_no 键名不合法（$key），已跳过"
        continue
        ;;
    esac
    if [ -z "$value" ]; then
      # 空值 = 该能力不配置：登记键名以便打印，但不注入 --dart-define。
      add_key "$key"
      continue
    fi
    set_define "$key" "$value" "本地配置文件" 0
  done < "$LOCAL_ENV_FILE"
else
  echo "    （未找到配置文件；可 cp tool/release_defines.local.env.example 后填入）"
fi

# ---------------------------------------------------------------------------
# 3) 环境变量覆盖文件值（同名即覆盖；空值不覆盖，避免 CI 里的空变量误清空）。
# ---------------------------------------------------------------------------
for key in ${KEYS_ORDER[@]+"${KEYS_ORDER[@]}"}; do
  env_value="${!key-}"
  if [ -n "$env_value" ]; then
    set_define "$key" "$env_value" "环境变量" 0
  fi
done

# ---------------------------------------------------------------------------
# 4) 组装最终 flutter 参数：未被命令行显式覆盖的非空配置自动追加。
# ---------------------------------------------------------------------------
FINAL_ARGS=(${FLUTTER_ARGS[@]+"${FLUTTER_ARGS[@]}"})
INJECTED_KEYS=()
for key in ${KEYS_ORDER[@]+"${KEYS_ORDER[@]}"}; do
  value="${DEFINE_VALUE[$key]:-}"
  if [ -z "$value" ]; then
    continue
  fi
  INJECTED_KEYS+=("$key")
  if [ "${DEFINE_EXPLICIT[$key]:-0}" = "1" ]; then
    continue
  fi
  FINAL_ARGS+=("--dart-define=$key=$value")
done

echo "==> 编译期配置（--dart-define，只显示键名，不回显值）"
for key in ${KEYS_ORDER[@]+"${KEYS_ORDER[@]}"}; do
  value="${DEFINE_VALUE[$key]:-}"
  src="${DEFINE_SOURCE[$key]:-}"
  if [ -n "$value" ]; then
    printf '    [注入] %-24s 来源：%s\n' "$key" "$src"
  else
    printf '    [空]   %-24s 未注入\n' "$key"
  fi
done

# 识图地址必须是 https，否则客户端直接拒绝使用（构建期先提醒）。
vision_url="${DEFINE_VALUE[MINGTU_VISION_PROXY_URL]:-}"
if [ -n "$vision_url" ]; then
  case "$vision_url" in
    https://*) : ;;
    *) echo "!! [WARN] MINGTU_VISION_PROXY_URL 不是 https 地址，App 会拒绝使用云端识图（值不回显）" ;;
  esac
fi

# ---------------------------------------------------------------------------
# 5) 路线配置检查：缺了就显式告警（或按 --require-routes 直接失败）。
# ---------------------------------------------------------------------------
ROUTE_READY=0
for key in "${ROUTE_KEYS[@]}"; do
  if [ -n "${DEFINE_VALUE[$key]:-}" ]; then
    ROUTE_READY=1
  fi
done

MISSING_DOC_KEYS=()
for key in "${DOC_KEYS[@]}"; do
  if [ -z "${DEFINE_VALUE[$key]:-}" ]; then
    MISSING_DOC_KEYS+=("$key")
  fi
done

if [ "$ROUTE_READY" = "0" ]; then
  echo
  echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
  echo "!! 警告：此包未注入路线配置，导航/路线演示不可用（只能启动与本地功能）"
  echo "!! MINGTU_AMAP_KEY 与 MINGTU_ROUTE_PROXY_URL 都为空。"
  echo "!! 注入方法：cp tool/release_defines.local.env.example \\"
  echo "!!              tool/release_defines.local.env 后填入，或用环境变量传入。"
  echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
  if [ "$REQUIRE_ROUTES" = "1" ]; then
    echo "!! 已指定 --require-routes：路线配置缺失，构建终止（未产出新包）。"
    echo "!! 注意：构建目录里已有的 app-release.apk 是上一次的产物，不是本次构建结果。"
    exit 1
  fi
else
  echo "==> 路线配置已注入（MINGTU_AMAP_KEY / MINGTU_ROUTE_PROXY_URL 至少一项非空）"
fi

# ---------------------------------------------------------------------------
# 6) 构建（非 ASCII 路径走 ASCII 镜像）。
# ---------------------------------------------------------------------------
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
  build_in "$REPO_ROOT" ${FINAL_ARGS[@]+"${FINAL_ARGS[@]}"}
  APK="$REPO_ROOT/build/app/outputs/flutter-apk/app-release.apk"
else
  echo "!! 项目路径含非 ASCII 字符：$REPO_ROOT"
  echo "!! 按上面注释的原因，改为在 ASCII 镜像目录构建：$MIRROR"
  mkdir -p "$MIRROR"

  # 镜像工作副本（保留未提交改动），排除构建缓存、.git 和本地密钥文件。
  # robocopy 的退出码 0-7 都算成功（1 = 复制了新文件）。
  if command -v robocopy >/dev/null 2>&1; then
    set +e
    robocopy "$(cygpath -w "$REPO_ROOT")" "$(cygpath -w "$MIRROR")" /E \
      /XD build .dart_tool .git .kotlin \
      /XF release_defines.local.env \
      /NFL /NDL /NJH /NJS /NP
    rc=$?
    set -e
    [ "$rc" -lt 8 ] || { echo "robocopy 失败，exit=$rc"; exit 1; }
  else
    # 非 Windows 的兜底：rsync 优先
    command -v rsync >/dev/null 2>&1 || { echo "需要 robocopy 或 rsync 才能镜像目录"; exit 1; }
    rsync -a --delete \
      --exclude build --exclude .dart_tool --exclude .git --exclude .kotlin \
      --exclude 'release_defines.local.env' \
      "$REPO_ROOT"/ "$MIRROR"/
  fi

  build_in "$MIRROR" ${FINAL_ARGS[@]+"${FINAL_ARGS[@]}"}

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

# ---------------------------------------------------------------------------
# 7) 校验配置真的进了包：解出 libapp.so，按字节搜索每个注入的值。
#    找不到 = 脚本的注入链路坏了，必须失败（不能产出「配置缺失」的包）。
# ---------------------------------------------------------------------------
PYTHON_BIN_RESOLVED=""
for candidate in "${PYTHON_BIN:-}" python3 python py; do
  if [ -z "$candidate" ]; then
    continue
  fi
  if command -v "$candidate" >/dev/null 2>&1; then
    PYTHON_BIN_RESOLVED="$candidate"
    break
  fi
done
if [ -z "$PYTHON_BIN_RESOLVED" ]; then
  echo "!! 需要 python3 才能校验 --dart-define 是否真的进了包（本步骤不允许跳过）"
  exit 1
fi

# Git Bash / Cygwin 的 python 是原生 Windows 程序，不认 /d/... 这类路径，
# 参数一律先转成本机路径；Linux 上没有 cygpath，原样使用。
to_native_path() {
  if command -v cygpath >/dev/null 2>&1; then
    cygpath -w "$1"
  else
    printf '%s' "$1"
  fi
}

# 值只经由临时文件（权限 600）传给 python：不走命令行、不进日志。
DEFINES_MANIFEST="$(mktemp 2>/dev/null || mktemp -t mingtu-defines)"
TMP_FILES+=("$DEFINES_MANIFEST")
chmod 600 "$DEFINES_MANIFEST" 2>/dev/null || true
for key in ${INJECTED_KEYS[@]+"${INJECTED_KEYS[@]}"}; do
  printf '%s\t%s\n' "$key" "${DEFINE_VALUE[$key]}" >> "$DEFINES_MANIFEST"
done

VERIFY_SCRIPT="$(mktemp 2>/dev/null || mktemp -t mingtu-verify)"
TMP_FILES+=("$VERIFY_SCRIPT")
cat > "$VERIFY_SCRIPT" <<'PY'
"""校验 --dart-define 的值是否真的编进了 release 的 libapp.so。

输入：stdin 每行 "KEY<TAB>VALUE"（值只走进程间管道，不进命令行、不进日志）。
输出：每项打印 [OK]/[FAIL]（只打印 KEY，绝不打印 VALUE）。
退出码：全部命中 0；有任一未命中 1；APK/so 不可读 1。
"""
import sys
import zipfile


def read_pairs(stream):
    """把 stdin 解析成 [(key, value)]，忽略空行。"""
    pairs = []
    for raw in stream.read().splitlines():
        if not raw.strip():
            continue
        key, _, value = raw.partition("\t")
        key = key.strip()
        if key:
            pairs.append((key, value))
    return pairs


def load_native_lib(apk_path):
    """从 APK 里取 arm64 的 libapp.so 字节，取不到返回 (None, None)。"""
    try:
        archive = zipfile.ZipFile(apk_path)
    except (OSError, zipfile.BadZipFile) as exc:
        print("[FAIL] 无法读取 APK：%s" % exc)
        return None, None
    with archive:
        names = [n for n in archive.namelist()
                 if n.endswith("/libapp.so") or n == "libapp.so"]
        arm64 = [n for n in names if "arm64-v8a" in n]
        target = (arm64 or names or [None])[0]
        if target is None:
            print("[FAIL] APK 内找不到 libapp.so，无法校验配置是否进包")
            return None, None
        return target, archive.read(target)


def main():
    if len(sys.argv) != 2:
        print("用法：verify_defines.py <apk> < defines(KEY<TAB>VALUE)")
        return 2
    apk_path = sys.argv[1]
    pairs = [(k, v) for k, v in read_pairs(sys.stdin) if v]
    if not pairs:
        print("==> 没有非空注入项，跳过进包校验（配置全空时无可搜字节）")
        return 0

    target, blob = load_native_lib(apk_path)
    if blob is None:
        return 1
    print("==> 校验目标：%s（%.1f MB）" % (target, len(blob) / 1024 / 1024))

    failed = []
    for key, value in pairs:
        if value.encode("utf-8") in blob:
            print("[OK] %s 已进包" % key)
        else:
            failed.append(key)
            print("[FAIL] %s 未进包" % key)
    if failed:
        print("!! 以下配置的值在 libapp.so 里找不到，注入链路有问题：" + ", ".join(failed))
        print("!! 这样出的包会缺配置（App 会播报「路线不可用」），已判定构建失败。")
        return 1
    print("==> 全部 %d 项注入配置均已确认进包（只做字节存在性比对，不回显值）" % len(pairs))
    return 0


if __name__ == "__main__":
    sys.exit(main())
PY

echo
echo "==> 校验编译期配置是否进包（解出 libapp.so 做字节比对，不回显值）"
VERIFY_SCRIPT_ARG="$(to_native_path "$VERIFY_SCRIPT")"
APK_ARG="$(to_native_path "$APK")"
set +e
"$PYTHON_BIN_RESOLVED" "$VERIFY_SCRIPT_ARG" "$APK_ARG" < "$DEFINES_MANIFEST"
VERIFY_RC=$?
set -e
rm -f "$DEFINES_MANIFEST" "$VERIFY_SCRIPT" 2>/dev/null || true
if [ "$VERIFY_RC" -ne 0 ]; then
  echo "!! 进包校验失败，判定本次构建无效（exit=$VERIFY_RC）。"
  exit "$VERIFY_RC"
fi

# ---------------------------------------------------------------------------
# 8) 缺路线配置时，在 APK 同目录留一份说明，避免这个包被误发出去。
# ---------------------------------------------------------------------------
NOTICE="$APK.NOTICE.txt"
if [ "$ROUTE_READY" = "1" ]; then
  rm -f "$NOTICE"   # 路线配置齐全时清掉上一次遗留的说明
else
  {
    echo "此 APK 缺少路线配置，不能作为导航/路线演示包。"
    echo
    echo "构建时间：$(date '+%Y-%m-%d %H:%M:%S')"
    echo "APK：$(basename "$APK")"
    echo
    echo "未注入的编译期配置（--dart-define）："
    for key in "${MISSING_DOC_KEYS[@]}"; do
      echo "  - $key"
    done
    echo
    echo "后果："
    echo "  - App 能安装、能启动，本地功能（无障碍朗读、摄像头取景等）可用；"
    echo "  - 真实路线规划与导航演示不可用，App 会播报「路线不可用」；"
    echo "  - 未配置识图/语音代理时，云端识图与语音回退同样不可用。"
    echo
    echo "如何生成可演示的包："
    echo "  1) cp tool/release_defines.local.env.example tool/release_defines.local.env"
    echo "  2) 填入 MINGTU_AMAP_KEY 或 MINGTU_ROUTE_PROXY_URL"
    echo "     （该文件已被 .gitignore 忽略，绝不提交）"
    echo "  3) bash tool/build_release_apk.sh"
    echo "  也可用环境变量：MINGTU_AMAP_KEY=xxx bash tool/build_release_apk.sh"
    echo
    echo "正式交付请加 --require-routes：缺路线配置时构建直接失败。"
  } > "$NOTICE"
  echo
  echo "==> 已写入说明文件：$NOTICE"
fi

echo
echo "==> 完成"
