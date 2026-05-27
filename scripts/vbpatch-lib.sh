#!/system/bin/sh

MODDIR=${MODDIR:-${0%/*}}
MODDIR=${MODDIR%/scripts}
STATE_DIR="$MODDIR/var"
LOG_DIR="$STATE_DIR/log"
TMP_DIR="$STATE_DIR/tmp"
DEFAULT_OUT_DIR="/sdcard/Download/vbpatch"

mkdir -p "$STATE_DIR" "$LOG_DIR" "$TMP_DIR" 2>/dev/null

log() {
  printf '%s\n' "$*"
}

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

resolve_path() {
  local target resolved abs dir base
  target=$1
  if command -v readlink >/dev/null 2>&1; then
    resolved=$(readlink -f "$target" 2>/dev/null)
    if [ -n "$resolved" ]; then
      printf '%s\n' "$resolved"
      return 0
    fi
  fi

  case "$target" in
    /*) abs=$target ;;
    *) abs="$(pwd)/$target" ;;
  esac

  dir=${abs%/*}
  base=${abs##*/}
  (
    cd "$dir" 2>/dev/null || exit 1
    printf '%s/%s\n' "$(pwd -P)" "$base"
  )
}

get_size_bytes() {
  local path size real_path block_name sys_size sectors
  path=$1

  if [ -b "$path" ]; then
    if command -v blockdev >/dev/null 2>&1; then
      size=$(blockdev --getsize64 "$path" 2>/dev/null)
      if [ -n "$size" ]; then
        printf '%s\n' "$size"
        return 0
      fi
    fi

    real_path=$(resolve_path "$path") || return 1
    block_name=${real_path##*/}
    sys_size="/sys/class/block/$block_name/size"
    if [ -r "$sys_size" ]; then
      sectors=$(cat "$sys_size" 2>/dev/null)
      if [ -n "$sectors" ]; then
        printf '%s\n' $((sectors * 512))
        return 0
      fi
    fi
  fi

  wc -c < "$path" | tr -d '[:space:]'
}

read_hex_range() {
  local path offset count
  path=$1
  offset=$2
  count=$3
  dd if="$path" bs=1 skip="$offset" count="$count" 2>/dev/null | od -An -tx1 | tr -d '[:space:]'
}

be64_at() {
  local path offset hex
  path=$1
  offset=$2
  hex=$(read_hex_range "$path" "$offset" 8)
  [ -n "$hex" ] || hex=0
  printf '%s\n' $((0x$hex))
}

write_be64() {
  local value out shift byte
  value=$1
  out=$2
  shift=56
  while [ "$shift" -ge 0 ]; do
    byte=$(((value >> shift) & 255))
    printf "\\$(printf '%03o' "$byte")" >> "$out"
    shift=$((shift - 8))
  done
}

find_byname_dir() {
  local dir
  for dir in \
    /dev/block/by-name \
    /dev/block/bootdevice/by-name \
    /dev/block/bootdevice/*/by-name \
    /dev/block/platform/*/by-name
  do
    [ -d "$dir" ] || continue
    printf '%s\n' "$dir"
    return 0
  done
  return 1
}

partition_allowed() {
  local name
  name=$1
  case "$name" in
    vbmeta*|boot*|init_boot*|vendor_boot*|vendor_kernel_boot*|recovery*|dtbo*)
      return 0
      ;;
  esac
  return 1
}

probe_avb() {
  local path size kind orig_size vbmeta_offset vbmeta_size footer_offset footer_magic header_magic auth_size aux_size
  path=$1
  size=$(get_size_bytes "$path") || return 1

  kind=none
  orig_size=
  vbmeta_offset=
  vbmeta_size=

  if [ "$size" -ge 64 ]; then
    footer_offset=$((size - 64))
    footer_magic=$(read_hex_range "$path" "$footer_offset" 4)
    if [ "$footer_magic" = "41564266" ]; then
      kind=footer
      orig_size=$(be64_at "$path" $((footer_offset + 12)))
      vbmeta_offset=$(be64_at "$path" $((footer_offset + 20)))
      vbmeta_size=$(be64_at "$path" $((footer_offset + 28)))
    fi
  fi

  if [ "$kind" = "none" ]; then
    header_magic=$(read_hex_range "$path" 0 4)
    if [ "$header_magic" = "41564230" ]; then
      auth_size=$(be64_at "$path" 12)
      aux_size=$(be64_at "$path" 20)
      kind=header
      orig_size=$size
      vbmeta_offset=0
      vbmeta_size=$((256 + auth_size + aux_size))
    fi
  fi

  printf '%s|%s|%s|%s|%s\n' "$kind" "$size" "${orig_size:-0}" "${vbmeta_offset:-0}" "${vbmeta_size:-0}"
}

partition_path() {
  local byname_dir part_name part_path
  byname_dir=$1
  part_name=$2
  part_path="$byname_dir/$part_name"
  [ -e "$part_path" ] || return 1
  printf '%s\n' "$part_path"
}

list_partitions() {
  local byname_dir
  byname_dir=$(find_byname_dir) || fail "未找到 by-name 分区目录"
  printf 'META|byname|%s\n' "$byname_dir"

  for entry in "$byname_dir"/*; do
    [ -e "$entry" ] || continue
    name=${entry##*/}
    partition_allowed "$name" || continue
    probe=$(probe_avb "$entry") || continue
    printf 'PART|%s|%s|%s\n' "$name" "$entry" "$probe"
  done | sort
}

copy_prefix() {
  local src bytes out
  src=$1
  bytes=$2
  out=$3
  head -c "$bytes" "$src" > "$out" || return 1
}

extract_vbmeta() {
  local src out probe kind vbmeta_offset vbmeta_size magic
  src=$1
  out=$2

  probe=$(probe_avb "$src") || return 1
  kind=$(printf '%s' "$probe" | cut -d'|' -f1)
  vbmeta_offset=$(printf '%s' "$probe" | cut -d'|' -f4)
  vbmeta_size=$(printf '%s' "$probe" | cut -d'|' -f5)

  [ "$kind" = "footer" ] || [ "$kind" = "header" ] || fail "源镜像未找到有效 AVB 数据"
  [ "$vbmeta_size" -gt 0 ] || fail "源镜像中的 VBMeta 大小无效"

  dd if="$src" of="$out" bs=1 skip="$vbmeta_offset" count="$vbmeta_size" 2>/dev/null || return 1

  magic=$(read_hex_range "$out" 0 4)
  [ "$magic" = "41564230" ] || fail "提取出的 VBMeta 头校验失败"

  printf '%s|%s|%s\n' "$kind" "$vbmeta_offset" "$vbmeta_size"
}

build_footer() {
  local orig_size vbmeta_offset vbmeta_size out
  orig_size=$1
  vbmeta_offset=$2
  vbmeta_size=$3
  out=$4

  : > "$out"
  printf 'AVBf\000\000\000\001\000\000\000\000' >> "$out"
  write_be64 "$orig_size" "$out"
  write_be64 "$vbmeta_offset" "$out"
  write_be64 "$vbmeta_size" "$out"
  head -c 28 /dev/zero >> "$out"
}

patch_core() {
  local src tgt out_img tmp_vbmeta tmp_footer extract_info src_mode v_offset_src v_size tgt_probe tgt_kind tgt_size orig_size vbmeta_offset footer_offset req_size padding_size out_size footer_magic
  src=$1
  tgt=$2
  out_img=$3

  tmp_vbmeta=$(mktemp "$TMP_DIR/vbmeta.XXXXXX") || fail "无法创建临时 VBMeta 文件"
  tmp_footer=$(mktemp "$TMP_DIR/footer.XXXXXX") || fail "无法创建临时 Footer 文件"
  trap 'rm -f "$tmp_vbmeta" "$tmp_footer"' EXIT INT TERM

  log "[1/5] 正在提取源镜像中的 VBMeta"
  extract_info=$(extract_vbmeta "$src" "$tmp_vbmeta")
  src_mode=$(printf '%s' "$extract_info" | cut -d'|' -f1)
  v_offset_src=$(printf '%s' "$extract_info" | cut -d'|' -f2)
  v_size=$(printf '%s' "$extract_info" | cut -d'|' -f3)
  log "  源镜像模式: $src_mode"
  log "  源 VBMeta 偏移: $v_offset_src"
  log "  源 VBMeta 大小: $v_size"

  log "[2/5] 正在分析目标镜像布局"
  tgt_probe=$(probe_avb "$tgt") || fail "无法读取目标镜像信息"
  tgt_kind=$(printf '%s' "$tgt_probe" | cut -d'|' -f1)
  tgt_size=$(printf '%s' "$tgt_probe" | cut -d'|' -f2)

  if [ "$tgt_kind" = "footer" ]; then
    orig_size=$(printf '%s' "$tgt_probe" | cut -d'|' -f3)
    log "  目标镜像已有 AVB Footer"
  else
    orig_size=$((tgt_size - v_size - 64))
    log "  目标镜像无 AVB Footer，按原始数据镜像处理"
  fi

  [ "$orig_size" -gt 0 ] || fail "目标镜像原始数据大小无效"

  vbmeta_offset=$orig_size
  footer_offset=$((tgt_size - 64))
  req_size=$((orig_size + v_size + 64))
  padding_size=$((footer_offset - vbmeta_offset - v_size))

  [ "$req_size" -le "$tgt_size" ] || fail "目标镜像空间不足，需要 $req_size 字节，实际只有 $tgt_size 字节"
  [ "$padding_size" -ge 0 ] || fail "计算出的填充大小无效"

  log "  目标镜像总大小: $tgt_size"
  log "  原始数据大小: $orig_size"
  log "  新 VBMeta 偏移: $vbmeta_offset"
  log "  Footer 偏移: $footer_offset"
  log "  填充大小: $padding_size"

  log "[3/5] 正在组装修补后的镜像"
  copy_prefix "$tgt" "$orig_size" "$out_img" || fail "写入目标镜像原始数据失败"
  cat "$tmp_vbmeta" >> "$out_img" || fail "写入 VBMeta 数据失败"
  if [ "$padding_size" -gt 0 ]; then
    head -c "$padding_size" /dev/zero >> "$out_img" || fail "写入填充区失败"
  fi
  build_footer "$orig_size" "$vbmeta_offset" "$v_size" "$tmp_footer"
  cat "$tmp_footer" >> "$out_img" || fail "写入 Footer 失败"

  log "[4/5] 正在校验输出镜像"
  out_size=$(get_size_bytes "$out_img") || fail "无法读取输出镜像大小"
  footer_magic=$(read_hex_range "$out_img" $((out_size - 64)) 4)
  [ "$footer_magic" = "41564266" ] || fail "输出镜像 Footer 校验失败"
  log "  输出镜像大小: $out_size"

  log "[5/5] 修补完成"
  trap - EXIT INT TERM
  rm -f "$tmp_vbmeta" "$tmp_footer"
}

patch_from_partitions() {
  local src_name tgt_name output_dir flash_back byname_dir src_path tgt_path timestamp out_img backup_img
  src_name=$1
  tgt_name=$2
  output_dir=${3:-$DEFAULT_OUT_DIR}
  flash_back=${4:-0}

  byname_dir=$(find_byname_dir) || fail "未找到 by-name 分区目录"
  src_path=$(partition_path "$byname_dir" "$src_name") || fail "源分区不存在: $src_name"
  tgt_path=$(partition_path "$byname_dir" "$tgt_name") || fail "目标分区不存在: $tgt_name"

  mkdir -p "$output_dir" || fail "无法创建输出目录: $output_dir"

  timestamp=$(date +%Y%m%d-%H%M%S 2>/dev/null)
  [ -n "$timestamp" ] || timestamp=$(busybox date +%Y%m%d-%H%M%S 2>/dev/null)
  [ -n "$timestamp" ] || timestamp=now

  out_img="$output_dir/${tgt_name}_patched_${timestamp}.img"
  backup_img="$output_dir/${tgt_name}_backup_${timestamp}.img"

  log "源分区: $src_name -> $src_path"
  log "目标分区: $tgt_name -> $tgt_path"
  log "输出目录: $output_dir"
  patch_core "$src_path" "$tgt_path" "$out_img"

  if [ "$flash_back" = "1" ]; then
    log "正在备份目标分区到: $backup_img"
    cat "$tgt_path" > "$backup_img" || fail "备份目标分区失败"
    log "正在将修补后的镜像回写到目标分区"
    dd if="$out_img" of="$tgt_path" bs=4M conv=fsync 2>/dev/null || fail "回写目标分区失败"
    log "回写完成，请自行决定是否重启验证"
  fi

  printf 'RESULT|output|%s\n' "$out_img"
  if [ "$flash_back" = "1" ]; then
    printf 'RESULT|backup|%s\n' "$backup_img"
    printf 'RESULT|flashed|1\n'
  else
    printf 'RESULT|flashed|0\n'
  fi
}

patch_from_files() {
  local src tgt out_img out_dir
  src=$1
  tgt=$2
  out_img=$3

  [ -f "$src" ] || fail "源镜像不存在: $src"
  [ -f "$tgt" ] || fail "目标镜像不存在: $tgt"

  out_dir=${out_img%/*}
  [ "$out_dir" = "$out_img" ] && out_dir=.
  mkdir -p "$out_dir" || fail "无法创建输出目录: $out_dir"

  log "源镜像: $src"
  log "目标镜像: $tgt"
  log "输出镜像: $out_img"
  patch_core "$src" "$tgt" "$out_img"
  printf 'RESULT|output|%s\n' "$out_img"
  printf 'RESULT|flashed|0\n'
}
