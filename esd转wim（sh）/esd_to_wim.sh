#!/usr/bin/env bash
# ============================================================================
#  esd_to_wim.sh  v1.5  —  查看 install.esd 并提取 WIM
#  运行环境：Windows + Git Bash（管理员）
#
#  更新历史：
#    v1.1  用 Get-WindowsImage 获取结构化信息，避免中文 DISM 输出乱码
#    v1.2  ask_index 提示改到 stderr，避免污染 $(...) 返回值
#    v1.3  resolve_esd 提示文字改用双引号，正确显示颜色
#    v1.4  导出改为后台 dism + 前台文件大小监控，避免"看似卡死"
#    v1.5  未指定 -c 时，交互式让用户选择压缩方式
# ============================================================================

set -o pipefail
export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL='*'

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_NAME="$(basename -- "${BASH_SOURCE[0]}")"

# ---- 颜色 ----
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  RST=$'\e[0m'; BOLD=$'\e[1m'; DIM=$'\e[2m'
  RED=$'\e[31m'; GRN=$'\e[32m'; YEL=$'\e[33m'
  BLU=$'\e[34m'; MAG=$'\e[35m'; CYN=$'\e[36m'
else
  RST=; BOLD=; DIM=; RED=; GRN=; YEL=; BLU=; MAG=; CYN=
fi

BAR="${DIM}────────────────────────────────────────────────────────────${RST}"

banner() {
  printf '\n%s\n' "$BAR"
  printf "  ${CYN}${BOLD}ESD${RST} ${MAG}→${RST} ${CYN}${BOLD}WIM${RST}   ${BOLD}映像查看与提取工具${RST}  ${DIM}v1.5${RST}\n"
  printf '%s\n' "$BAR"
}

step() { printf "\n${BLU}${BOLD}» %s${RST} ${BOLD}%s${RST}\n" "$1" "$2"; }
ok()   { printf "   ${GRN}✔${RST}  %s\n" "$1"; }
bad()  { printf "   ${RED}✘${RST}  %s\n" "$1"; }
warn() { printf "   ${YEL}▲${RST}  %s\n" "$1"; }
info() { printf "   ${DIM}·${RST}  %s\n" "$1"; }
die()  { printf '\n'; bad "$1"; printf '\n'; exit 1; }
trap 'printf "\n\n${YEL}已被用户中断。${RST}\n\n"; exit 130' INT

# ---- 路径工具 ----
win_path() {
  local p="$1"
  [[ "$p" != /* && ! "$p" =~ ^[A-Za-z]: ]] && p="$PWD/$p"
  if command -v cygpath >/dev/null 2>&1; then
    cygpath -w -- "$p" 2>/dev/null || printf '%s' "$p"
  else
    printf '%s' "$p"
  fi
}

unix_path() {
  local p="$1"
  if [[ "$p" =~ ^[A-Za-z]:[\\/] ]] && command -v cygpath >/dev/null 2>&1; then
    cygpath -u -- "$p" 2>/dev/null || printf '%s' "$p"
  else
    printf '%s' "$p"
  fi
}

human_size() {
  local f="$1" s
  s=$(stat -c %s -- "$f" 2>/dev/null) || { printf '?'; return; }
  awk -v b="$s" 'BEGIN {
    n = split("B KB MB GB TB", u, " "); i = 1
    while (b >= 1024 && i < n) { b /= 1024; i++ }
    printf (i == 1 ? "%.0f %s" : "%.2f %s"), b, u[i]
  }'
}

# ---------------------------------------------------------------------------
# 用 PowerShell 的 Get-WindowsImage 获取结构化信息（避开编码问题）
# 输出：每行  "<index>\t<name>"
# ---------------------------------------------------------------------------
fetch_images() {
  local w="$1"
  local w_ps="${w//\'/\'\'}"   # 转义单引号

  powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    \$OutputEncoding          = [System.Text.Encoding]::UTF8
    \$ErrorActionPreference   = 'Stop'
    try {
      \$imgs = @(Get-WindowsImage -ImagePath '$w_ps' -ErrorAction Stop)
      foreach (\$i in \$imgs) {
        [Console]::Out.WriteLine([string]\$i.ImageIndex + [char]9 + [string]\$i.ImageName)
      }
    } catch {
      [Console]::Error.WriteLine('PSErr: ' + \$_.Exception.Message)
      exit 3
    }
  " 2>&1 | tr -d '\r'
}

# 兜底：DISM 文本输出 + Perl 转码
fetch_images_fallback() {
  local w="$1"
  local raw
  raw=$(cmd.exe /c "chcp 65001 >nul && dism.exe /Get-WimInfo /WimFile:\"$w\"" 2>&1 \
        | tr -d '\r' \
        | sed -e 's/\x1b\[[0-9;]*[A-Za-z]//g')

  local enc="CP936"
  if command -v iconv >/dev/null 2>&1; then
    raw=$(printf '%s' "$raw" | iconv -f "$enc" -t UTF-8 -c 2>/dev/null || printf '%s' "$raw")
  elif command -v perl >/dev/null 2>&1; then
    raw=$(printf '%s' "$raw" | perl -MEncode -e '
      binmode STDIN, ":raw"; binmode STDOUT, ":utf8";
      local $/; my $d = <STDIN>;
      my $o = eval { Encode::decode("CP936", $d, Encode::FB_DEFAULT) };
      print defined($o) ? $o : $d;
    ' 2>/dev/null || printf '%s' "$raw")
  fi

  printf '%s\n' "$raw" | awk '
    function trim(s){ sub(/^[ \t\r]+/,"",s); sub(/[ \t\r]+$/,"",s); return s }
    /(Index|索引)[ \t]*[:：]/ {
      v=$0; sub(/^[^:：]*[:：][ \t]*/,"",v); gsub(/[^0-9]/,"",v)
      if (v!="") { idx=v; want=1 }
      next
    }
    want==1 && /(Name|名称)[ \t]*[:：]/ {
      v=$0; sub(/^[^:：]*[:：][ \t]*/,"",v)
      printf "%s\t%s\n", idx, trim(v)
      want=0
    }
  '
}

# ---------------------------------------------------------------------------
# 导出：dism 后台运行，前台显示输出文件大小 + 已用时间
# ---------------------------------------------------------------------------
export_image() {
  local src="$1" idx="$2" dst="$3" rc
  local log; log=$(mktemp)

  dism.exe /Export-Image \
      /SourceImageFile:"$src" \
      /SourceIndex:"$idx" \
      /DestinationImageFile:"$dst" \
      /Compress:"$COMPRESS" > "$log" 2>&1 &
  local pid=$!

  local start last_size size elapsed rate sz_str rate_str
  start=$(date +%s)
  last_size=-1

  printf "    ⏳ 导出中"
  while kill -0 "$pid" 2>/dev/null; do
    size=0
    if [[ -e "$dst" ]]; then
      size=$(stat -c %s -- "$dst" 2>/dev/null || echo 0)
    fi

    if [[ "$size" != "$last_size" ]]; then
      elapsed=$(( $(date +%s) - start ))
      [[ $elapsed -lt 1 ]] && elapsed=1
      rate=$(( size / elapsed ))

      sz_str=$(awk -v b="$size" 'BEGIN {
        n=split("B KB MB GB TB", u, " "); i=1
        while (b>=1024 && i<n) { b/=1024; i++ }
        printf (i==1 ? "%.0f %s" : "%.1f %s"), b, u[i]
      }')
      rate_str=$(awk -v b="$rate" 'BEGIN {
        n=split("B/s KB/s MB/s GB/s", u, " "); i=1
        while (b>=1024 && i<n) { b/=1024; i++ }
        printf (i==1 ? "%.0f %s" : "%.1f %s"), b, u[i]
      }')

      printf "\r    ⏳ 已写入 %-11s  用时 %3ds  速度 %-10s" "$sz_str" "$elapsed" "$rate_str"
      last_size="$size"
    fi
    sleep 2
  done

  wait "$pid"
  rc=$?

  if [[ $rc -ne 0 ]]; then
    printf "\n"
    if [[ -s "$log" ]]; then
      printf "    ${RED}DISM 输出：${RST}\n"
      tr -d '\r' < "$log" | sed 's/^/      /' | head -20
    fi
  else
    printf "\r    ✔ 导出进程已结束                              \n"
  fi

  rm -f -- "$log"
  return "$rc"
}

# ---------------------------------------------------------------------------
# 参数
# ---------------------------------------------------------------------------
ESD_FILE=""; OUT_FILE=""; INDEX_SEL=""
COMPRESS="max"; COMPRESS_SET=0
LIST_ONLY=0; ASSUME_YES=0

usage() {
  cat <<EOF

${BOLD}用法${RST}: $SCRIPT_NAME [选项] [install.esd 路径]

${BOLD}选项${RST}:
  -i, --index <n>        指定提取索引：单个数(2)｜多个(1,3)｜区间(1-3)｜全部(all)
  -o, --output <file>    输出文件名（单索引）
  -c, --compress <t>     max | fast | none   (默认: 交互选择，-y 时用 max)
  -l, --list             只列信息，不提取
  -y, --yes              跳过所有交互（索引默认 1，压缩默认 max）
  -h, --help             帮助

${BOLD}压缩方式${RST}:
  max   LZX     压缩率最高，文件最小，速度最慢
  fast  XPRESS  压缩率中等，速度快，推荐日常装机
  none  不压缩  最快，文件最大

${BOLD}示例${RST}:
  $SCRIPT_NAME                        # 全程交互
  $SCRIPT_NAME -i 2                   # 指定索引，压缩仍交互
  $SCRIPT_NAME -i 2 -c fast           # 全指定，仍确认
  $SCRIPT_NAME -i 2 -c fast -y        # 全自动，不询问
  $SCRIPT_NAME -l                     # 只看列表

EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -i|--index)     INDEX_SEL="$2";    shift 2 ;;
      -o|--output)    OUT_FILE="$2";     shift 2 ;;
      -c|--compress)  COMPRESS="$2"; COMPRESS_SET=1; shift 2 ;;
      -l|--list)      LIST_ONLY=1;       shift ;;
      -y|--yes)       ASSUME_YES=1;      shift ;;
      -h|--help)      banner; usage;     exit 0 ;;
      --)             shift; break ;;
      -*)             printf "未知选项: %s\n" "$1" >&2; usage; exit 2 ;;
      *)              ESD_FILE="$1";     shift ;;
    esac
  done
  case "$COMPRESS" in max|fast|none) ;; *) printf "无效压缩: %s\n" "$COMPRESS" >&2; exit 2 ;; esac
}

# ---------------------------------------------------------------------------
check_env() {
  command -v dism.exe       >/dev/null 2>&1 && ok "DISM 可用"        || die "未找到 dism.exe"
  command -v powershell.exe >/dev/null 2>&1 && ok "PowerShell 可用"  || warn "未找到 powershell.exe（将用 DISM 兜底）"
  if net.exe session >/dev/null 2>&1; then
    ok "已获得管理员权限"
  else
    bad "不是管理员权限"
    warn "请关闭本窗口，右键 Git Bash → 以管理员身份运行后重试。"
    exit 1
  fi
}

resolve_esd() {
  local c f p
  if [[ -n "$ESD_FILE" ]]; then
    p=$(unix_path "$ESD_FILE")
    [[ -f "$p" ]] || die "文件不存在: $p"
    printf '%s' "$p"; return
  fi
  for c in "$SCRIPT_DIR/install.esd" "$PWD/install.esd"; do
    [[ -f "$c" ]] && { printf '%s' "$c"; return; }
  done
  f=$(find "$SCRIPT_DIR" "$PWD" -maxdepth 1 -type f -iname '*.esd' 2>/dev/null | head -n1)
  [[ -n "$f" ]] && { printf '%s' "$f"; return; }

  printf "\n   ${BOLD}请输入 install.esd 完整路径${RST}${DIM}(可直接把文件拖进窗口)${RST}:\n   ${CYN}>${RST} " >&2
  read -r p
  p=$(printf '%s' "$p" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
                              -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//")
  [[ -n "$p" ]] || die "未输入路径"
  p=$(unix_path "$p")
  [[ -f "$p" ]] || die "文件不存在: $p"
  printf '%s' "$p"
}

show_table() {
  printf "\n   ${BOLD}%-8s %s${RST}\n" "索引" "名称"
  printf "   ${DIM}%-8s %s${RST}\n" "────" "──────────────────────────────────────────────"
  local idx name
  while IFS=$'\t' read -r idx name; do
    [[ -z "$idx" ]] && continue
    printf "   ${GRN}${BOLD}%-8s${RST} %s\n" "$idx" "$name"
  done
}

# ★ 提示走 stderr，返回值只含用户输入
ask_index() {
  printf "\n   ${BOLD}请选择要提取的映像索引${RST}\n" >&2
  printf "   ${DIM}可填：单个数(2) ｜ 多个用逗号(1,3) ｜ 区间(1-3) ｜ 全部(all) ｜ 直接回车=1${RST}\n" >&2
  printf "   ${CYN}>${RST} " >&2
  local a
  read -r a
  a="${a// /}"
  [[ -z "$a" ]] && a="1"
  printf '%s' "$a"
}

# ★ 新增：交互式选择压缩方式
ask_compress() {
  printf "\n   ${BOLD}请选择压缩方式${RST}\n" >&2
  printf "   ${GRN}${BOLD}1${RST}) ${BOLD}max${RST}   ${DIM}LZX    — 压缩率最高，文件最小，速度最慢（默认）${RST}\n" >&2
  printf "   ${GRN}${BOLD}2${RST}) ${BOLD}fast${RST}  ${DIM}XPRESS — 压缩率中等，速度快，推荐日常装机${RST}\n" >&2
  printf "   ${GRN}${BOLD}3${RST}) ${BOLD}none${RST}  ${DIM}不压缩 — 最快，文件最大${RST}\n" >&2
  printf "   ${DIM}可填 1/2/3 或 max/fast/none，直接回车=1${RST}\n" >&2
  printf "   ${CYN}>${RST} " >&2

  local a
  read -r a
  a="${a// /}"
  a=$(printf '%s' "$a" | tr '[:upper:]' '[:lower:]')

  case "$a" in
    ""|1|max)  printf 'max'  ;;
    2|fast)    printf 'fast' ;;
    3|none)    printf 'none' ;;
    *)
      printf "   ${YEL}输入无法识别，使用默认 max${RST}\n" >&2
      printf 'max'
      ;;
  esac
}

expand_selection() {
  local sel="$1" all="$2" part i
  local -a out=()
  local IFS=','
  for part in $sel; do
    if [[ "$part" == "all" || "$part" == "*" ]]; then
      # shellcheck disable=SC2206
      out=($all); break
    elif [[ "$part" =~ ^([0-9]+)-([0-9]+)$ ]]; then
      for ((i=${BASH_REMATCH[1]}; i<=${BASH_REMATCH[2]}; i++)); do out+=("$i"); done
    elif [[ "$part" =~ ^[0-9]+$ ]]; then
      out+=("$part")
    fi
  done
  printf '%s\n' "${out[@]}"
}

dst_for_index() {
  local idx="$1" total="$2"
  if [[ -n "$OUT_FILE" ]]; then
    if [[ "$OUT_FILE" = /* || "$OUT_FILE" =~ ^[A-Za-z]:[\\/] ]]; then
      printf '%s' "$OUT_FILE"
    else
      printf '%s/%s' "$ESD_DIR" "$OUT_FILE"
    fi
    return
  fi
  if [[ "$total" -eq 1 ]]; then
    printf '%s/install.wim' "$ESD_DIR"
  else
    printf '%s/install_%s.wim' "$ESD_DIR" "$idx"
  fi
}

# ---------------------------------------------------------------------------
main() {
  parse_args "$@"
  banner

  # ---- 1/7 环境 ----
  step "1/7" "环境检查"
  check_env

  # ---- 2/7 定位 ----
  step "2/7" "定位 install.esd"
  local esd
  esd=$(resolve_esd)
  [[ -n "$esd" ]] || die "未定位到 install.esd"
  ESD_DIR="$(cd -- "$(dirname -- "$esd")" && pwd)"
  local esd_win; esd_win=$(win_path "$esd")
  ok "文件: $esd"
  info "大小: $(human_size "$esd")"
  info "目录: $ESD_DIR"

  # ---- 3/7 读取映像 ----
  step "3/7" "读取映像信息"
  local info_txt
  info_txt=$(fetch_images "$esd_win")

  if ! printf '%s\n' "$info_txt" | grep -qE '^[0-9]+[[:space:]]'; then
    warn "PowerShell 方式未获取到映像，尝试 DISM 文本兜底……"
    info_txt=$(fetch_images_fallback "$esd_win")
  fi

  if ! printf '%s\n' "$info_txt" | grep -qE '^[0-9]+[[:space:]]'; then
    bad "无法解析映像信息，原始输出如下："
    printf '\n%s\n\n' "$info_txt"
    exit 1
  fi

  local -a ALL_IDX=()
  local i n
  while IFS=$'\t' read -r i n; do
    [[ -n "$i" ]] && ALL_IDX+=("$i")
  done <<< "$info_txt"

  ok "共发现 ${#ALL_IDX[@]} 个映像"
  show_table <<< "$info_txt"
  printf '\n'

  if [[ "$LIST_ONLY" -eq 1 ]]; then
    printf "   ${DIM}（--list 模式，不执行提取）${RST}\n\n"
    exit 0
  fi

  # ---- 4/7 选择索引 ----
  step "4/7" "选择要提取的映像"
  local sel
  if [[ -n "$INDEX_SEL" ]]; then
    sel="$INDEX_SEL"
    info "命令行指定: $sel"
  else
    sel=$(ask_index)
  fi

  local -a IDX_ARR=()
  local x
  while IFS= read -r x; do
    [[ -n "$x" ]] && IDX_ARR+=("$x")
  done < <(expand_selection "$sel" "${ALL_IDX[*]}")

  [[ ${#IDX_ARR[@]} -gt 0 ]] || die "没有解析出有效的索引号（输入: '$sel'）"

  local k found
  for k in "${IDX_ARR[@]}"; do
    found=0
    for x in "${ALL_IDX[@]}"; do
      [[ "$x" == "$k" ]] && { found=1; break; }
    done
    [[ $found -eq 1 ]] || die "索引 $k 不存在（可用: ${ALL_IDX[*]}）"
  done
  ok "已选择: ${IDX_ARR[*]}"

  # ---- 5/7 选择压缩方式 ----
  step "5/7" "选择压缩方式"
  if [[ "$COMPRESS_SET" -eq 1 ]]; then
    info "命令行指定: $COMPRESS"
  elif [[ "$ASSUME_YES" -eq 1 ]]; then
    info "已启用 -y，使用默认: $COMPRESS"
  else
    COMPRESS=$(ask_compress)
  fi
  ok "压缩方式: ${COMPRESS}"

  # ---- 6/7 确认 ----
  step "6/7" "确认操作"
  local name
  for i in "${IDX_ARR[@]}"; do
    name=$(printf '%s\n' "$info_txt" | awk -F'\t' -v k="$i" '$1==k{print $2; exit}')
    printf "   ${GRN}${BOLD}%s${RST}  %s\n" "$i" "$name"
  done
  printf '\n'
  info "压缩方式: ${COMPRESS}"
  info "输出目录: ${ESD_DIR}"

  if [[ "$ASSUME_YES" -eq 0 ]]; then
    printf "\n   ${BOLD}开始提取？${RST} ${DIM}[Y/n]${RST} "
    local ans; read -r ans
    case "$ans" in
      [Nn]|[Nn][Oo]) printf "\n   ${YEL}已取消。${RST}\n\n"; exit 0 ;;
    esac
  fi

  # ---- 7/7 导出 ----
  step "7/7" "导出 WIM"
  printf '\n'

  local total=${#IDX_ARR[@]}
  local done_n=0 failed=0
  local -a DONE_FILES=()

  for i in "${IDX_ARR[@]}"; do
    done_n=$((done_n+1))
    name=$(printf '%s\n' "$info_txt" | awk -F'\t' -v k="$i" '$1==k{print $2; exit}')

    local dst; dst=$(dst_for_index "$i" "$total")
    printf "${BOLD}[%s/%s]${RST} 索引 ${GRN}${BOLD}%s${RST} · %s\n" "$done_n" "$total" "$i" "$name"
    info "输出: $dst"

    if [[ -e "$dst" ]]; then
      warn "目标文件已存在"
      if [[ "$ASSUME_YES" -eq 0 ]]; then
        printf "      ${YEL}覆盖？${RST} [y/N] "
        local a; read -r a
        if [[ ! "$a" =~ ^[Yy]$ ]]; then
          info "已跳过"; printf '\n'; continue
        fi
      fi
      rm -f -- "$dst"
    fi

    local dst_win; dst_win=$(win_path "$dst")

    if export_image "$esd_win" "$i" "$dst_win"; then
      if [[ -s "$dst" ]]; then
        ok "完成 → $(basename -- "$dst")  ($(human_size "$dst"))"
        DONE_FILES+=("$dst")
      else
        bad "输出文件为空"; failed=1
      fi
    else
      bad "导出失败（索引 $i）"; failed=1
    fi
    printf '\n'
  done

  # ---- 总结 ----
  printf '%s\n' "$BAR"
  if [[ ${#DONE_FILES[@]} -gt 0 ]]; then
    printf "  ${GRN}${BOLD}✔ 全部完成${RST}  共 ${BOLD}%s${RST} 个映像\n\n" "${#DONE_FILES[@]}"
    local f
    for f in "${DONE_FILES[@]}"; do
      printf "    ${GRN}•${RST} %s  ${DIM}(%s)${RST}\n" "$f" "$(human_size "$f")"
    done
  else
    printf "  ${RED}${BOLD}✘ 没有生成任何文件${RST}\n"
  fi
  printf '%s\n\n' "$BAR"

  if [[ $failed -eq 0 && ${#DONE_FILES[@]} -gt 0 ]]; then
    exit 0
  else
    exit 1
  fi
}

main "$@"