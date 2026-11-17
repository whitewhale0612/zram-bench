#!/usr/bin/env bash
# zram 基准（主机侧）：推送脚本 → 设备上跑 zram-bench.sh → 拉回结果
#
#   ./run-zram-bench.sh                       默认 ALGOS="lz4kds lz4"
#   ./run-zram-bench.sh lz4kds lz4 zstd       位置参数即算法列表
#   FIO_RUNTIME=10 ./run-zram-bench.sh        其余环境变量原样传给设备脚本
#   NEW_SAMPLE=1 ./run-zram-bench.sh          设备上从 zram0 重新导出样本
#   SKIP_PUSH=1 / PULL=0                      不推送脚本 / 不拉回结果
#
# Ctrl-C：通知设备上的测试立即停止，并等它移除临时 zram、把 CPU / DDR 恢复为全频段。
#
# 样本：设备上 samples/zram0-<MB>M.bin 存在就复用；设备上没有而本机 samples/ 有，
#       就推上去复用；都没有，设备脚本从 zram0 导出。PULL_SAMPLE=1 把设备样本拉回本机。

set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
DEV_DIR=${DEV_DIR:-/data/local/tmp/zram-bench-package}
SAMPLE_MB=${SAMPLE_MB:-512}
SAMPLE_NAME=zram0-${SAMPLE_MB}M.bin
SKIP_PUSH=${SKIP_PUSH:-0}
PULL=${PULL:-1}
PULL_SAMPLE=${PULL_SAMPLE:-0}
[ $# -eq 0 ] || export ALGOS="$*"

# 传给设备脚本的变量（只传本机设置过的）
PASS_VARS="ALGOS BASELINE SAMPLE_MB SAMPLE NEW_SAMPLE IO_ORDERS FIO_RUNTIME FIO_JOBS
FIXED_CPU_FREQ_ENABLE FIXED_LITTLE_FREQ_MHZ FIXED_BIG_FREQ_MHZ FIXED_DDR_FREQ_ENABLE FIXED_DDR_MTS
SDDC_IDLE_GRACE_MS"

log() { printf '[host] %s\n' "$*" >&2; }
die() { log "错误: $*"; exit 1; }

SU=""
dsh() {   # 在设备 root shell 里执行一条命令串
    if [ -n "$SU" ]; then adb shell "su -c $(printf '%q' "$*")"; else adb shell "$*"; fi
}

check_device() {
    command -v adb >/dev/null || die "缺少 adb"
    [ "$(adb get-state 2>/dev/null || true)" = device ] || die "没有可用的 adb 设备"
    if [ "$(adb shell id -u | tr -d '\r')" != 0 ]; then
        [ "$(adb shell su -c id -u 2>/dev/null | tr -d '\r')" = 0 ] || die "设备没有 root"
        SU=1
    fi
    log "设备 $(adb get-serialno) $(adb shell getprop ro.product.model | tr -d '\r')"
}

push_package() {
    [ "$SKIP_PUSH" = 1 ] && return 0
    dsh "mkdir -p $DEV_DIR/bin $DEV_DIR/samples $DEV_DIR/results"
    adb push "$HERE/zram-bench.sh" "$HERE/README.md" "$DEV_DIR/" >/dev/null
    adb push "$HERE/bin/fio" "$HERE/bin/mkcorpus" "$DEV_DIR/bin/" >/dev/null
    dsh "chmod 755 $DEV_DIR/zram-bench.sh $DEV_DIR/bin/fio $DEV_DIR/bin/mkcorpus"

    if [ -z "${SAMPLE:-}" ] && [ "${NEW_SAMPLE:-0}" != 1 ] &&
       ! dsh "[ -s $DEV_DIR/samples/$SAMPLE_NAME ]" &&
       [ -s "$HERE/samples/$SAMPLE_NAME" ] && [ -f "$HERE/samples/$SAMPLE_NAME.meta" ]; then
        log "设备上没有样本，推送本机 samples/$SAMPLE_NAME"
        adb push "$HERE/samples/$SAMPLE_NAME" "$HERE/samples/$SAMPLE_NAME.meta" "$DEV_DIR/samples/" >/dev/null
        dsh "chmod 600 $DEV_DIR/samples/$SAMPLE_NAME $DEV_DIR/samples/$SAMPLE_NAME.meta"
    fi
}

run_device() {
    local env="" v ts
    ts=$(date +%Y%m%d-%H%M%S)
    DEV_RESULT=$DEV_DIR/results/$ts
    for v in $PASS_VARS; do
        [ -n "${!v+x}" ] && env+="$v=$(printf '%q' "${!v}") "
    done
    trap on_interrupt INT TERM
    dsh "cd $DEV_DIR && ${env}RESULT_DIR=$DEV_RESULT sh zram-bench.sh"
    trap - INT TERM
}

# adb 断开后设备上的脚本收不到信号，会继续跑完；所以中断时要主动通知它停止
on_interrupt() {
    trap - INT TERM
    printf '\n' >&2
    log "已中断，正在停止设备上的测试并恢复设备状态…"
    if ! dsh "cd $DEV_DIR && sh zram-bench.sh stop"; then
        log "警告: 恢复失败，请手动运行: adb shell su -c 'sh $DEV_DIR/zram-bench.sh restore'"
    fi
    exit 130
}

pull_back() {
    if [ "$PULL" = 1 ]; then
        mkdir -p "$HERE/results"
        adb pull "$DEV_RESULT" "$HERE/results/" >/dev/null || die "拉回结果失败"
        log "结果已拉回 results/$(basename "$DEV_RESULT")"
    fi
    if [ "$PULL_SAMPLE" = 1 ]; then
        mkdir -p "$HERE/samples"
        adb pull "$DEV_DIR/samples/." "$HERE/samples/" >/dev/null
        chmod 600 "$HERE"/samples/* 2>/dev/null || true
        log "样本已拉回 samples/"
    fi
}

check_device
push_package
run_device
pull_back
