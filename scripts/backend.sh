#!/system/bin/sh

MODDIR=${0%/*}
. "$MODDIR/vbpatch-lib.sh"

usage() {
  cat <<'EOF'
用法:
  backend.sh list
  backend.sh list-images [扫描目录列表]
  backend.sh patch <源分区名> <目标分区名> [输出目录] [是否回写:0|1]
  backend.sh patch-image <源分区名> <目标镜像> [输出目录] [是否回写:0|1] [回写分区名]
  backend.sh patch-file <源镜像> <目标镜像> <输出镜像>
EOF
}

cmd=$1
shift 2>/dev/null || true

case "$cmd" in
  list)
    list_partitions
    ;;
  list-images)
    list_images "$1"
    ;;
  patch)
    [ $# -ge 2 ] || fail "patch 至少需要源分区名和目标分区名"
    patch_from_partitions "$1" "$2" "$3" "$4"
    ;;
  patch-image)
    [ $# -ge 2 ] || fail "patch-image 至少需要源分区名和目标镜像路径"
    patch_partition_to_image "$1" "$2" "$3" "$4" "$5"
    ;;
  patch-file)
    [ $# -eq 3 ] || fail "patch-file 需要源镜像、目标镜像、输出镜像"
    patch_from_files "$1" "$2" "$3"
    ;;
  *)
    usage
    exit 1
    ;;
esac
