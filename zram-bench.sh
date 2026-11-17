#!/system/bin/sh
# zram 压缩算法基准（设备侧，单脚本，需 root）
#
#   sh zram-bench.sh                  准备样本 + 跑测 + 打印汇总
#   sh zram-bench.sh sample           只准备样本（已有则复用）
#   sh zram-bench.sh summary [DIR]    重新打印某次结果的汇总（默认最近一次）
#   sh zram-bench.sh stop             停止正在运行的测试并恢复设备状态
#   sh zram-bench.sh restore          测试被强制结束（kill -9、断电等）后手动恢复设备状态
#
# 样本：从 /dev/block/zram0 导出真正存着数据的页。空 slot（读出来是零）和同值页
#       （zram 不经过压缩器）都跳过，页均匀取自整个设备。结果存为
#       samples/zram0-<MB>M.bin + .meta，之后每次直接复用；NEW_SAMPLE=1 重新导出。
#       样本含其他进程的内存内容，文件权限 0600，不要外传。
#
# 跑测：hot-add 一个临时 zramN（不碰 zram0），disksize = 样本大小，用 dd 4K 写满，
#       等后台 pending 清零（内核有 sddc_stat 时）后记录 mm_stat，再用 fio 多线程随机读。
#       退出（含 Ctrl-C、出错）时停止 fio、移除 zramN，CPU 和 DDR 恢复为全频段
#       （min = 最低频率，max = 最高频率），governor 恢复为测试前的。
#
# 常用环境变量（括号内为默认值）：
#   ALGOS (lz4kds lz4)       要测的算法，空格分隔（默认列表在脚本 ALGOS= 一行）
#   BASELINE (lz4 或第一个)   汇总里百分比的对比基准
#   SAMPLE_MB (512)          样本大小
#   SAMPLE (samples/zram0-<MB>M.bin)  指定样本文件（可用旧样本）
#   NEW_SAMPLE (0)           1 = 忽略已有样本，从 zram0 重新导出
#   IO_ORDERS (0 1 2 3)      fio 块大小 4K/8K/16K/32K
#   FIO_RUNTIME (30)         每档秒数
#   FIO_JOBS (CPU 数)
#   FIXED_CPU_FREQ_ENABLE (1)  0 = 只设 performance governor，不锁频
#   FIXED_LITTLE_FREQ_MHZ (1552) / FIXED_BIG_FREQ_MHZ (1689)
#   FIXED_DDR_FREQ_ENABLE (1)  0 = DDR 不锁频（仍记录 fio 期间的实际频率）
#   FIXED_DDR_MTS (6389)     DDR 目标数据速率 MT/s，取最接近的档位（频率 = MT/s / 2）
#                            只支持高通 bus_dcvs（/sys/devices/system/cpu/bus_dcvs/DDR）
#   SDDC_IDLE_GRACE_MS (2000)  pending 清零后再等多久
#   RESULT_DIR (results/<时间>)

set -eu

D=$(cd "$(dirname "$0")" && pwd)

# 默认测试的算法：增删算法改这里（或运行时用 ALGOS="..." 覆盖）
# 注意 lz4kds 是作者内核特有的算法，官方内核没有，其他设备请改成内核支持的算法
ALGOS=${ALGOS:-lz4kds lz4}
BASELINE=${BASELINE:-}
SAMPLE_MB=${SAMPLE_MB:-512}
SAMPLE=${SAMPLE:-$D/samples/zram0-${SAMPLE_MB}M.bin}
SAMPLE_SRC=${SAMPLE_SRC:-/dev/block/zram0}
NEW_SAMPLE=${NEW_SAMPLE:-0}
IO_ORDERS=${IO_ORDERS:-0 1 2 3}
FIO_RUNTIME=${FIO_RUNTIME:-30}
FIO_JOBS=${FIO_JOBS:-$(grep -c '^processor' /proc/cpuinfo 2>/dev/null || echo 1)}
FIXED_CPU_FREQ_ENABLE=${FIXED_CPU_FREQ_ENABLE:-1}
FIXED_LITTLE_FREQ_MHZ=${FIXED_LITTLE_FREQ_MHZ:-1552}
FIXED_BIG_FREQ_MHZ=${FIXED_BIG_FREQ_MHZ:-1689}
FIXED_DDR_FREQ_ENABLE=${FIXED_DDR_FREQ_ENABLE:-1}
FIXED_DDR_MTS=${FIXED_DDR_MTS:-6389}
SDDC_IDLE_GRACE_MS=${SDDC_IDLE_GRACE_MS:-2000}
FIO=${FIO:-$D/bin/fio}
MKCORPUS=${MKCORPUS:-$D/bin/mkcorpus}
PG=4096

LOG=/dev/null
DDR_DIR=/sys/devices/system/cpu/bus_dcvs/DDR
STATE=$D/.bench-state      # 测试进行中的状态：pid、原 governor、临时 zram；正常结束后删除
cpu_locked=0
ddr_locked=0
ddr_sampler=""
fio_pid=""
bench_idx=""
bench_created=0

trap '' PIPE   # adb 断开后写终端会失败，但不能让脚本因 SIGPIPE 直接死掉、跳过恢复

# ---------- 输出 ----------
say()  { printf '%s\n' "$*" >&2; printf '%s\n' "$*" >> "$LOG"; }   # 终端 + 日志
note() { printf '%s\n' "$*" >> "$LOG"; }                            # 只进日志
part() { printf '%s' "$*" >&2; }                                     # 不换行的进度，只上终端
die()  { printf '\n错误: %s\n' "$*" >&2; printf '错误: %s\n' "$*" >> "$LOG"; exit 1; }

state_get() { sed -n "s|^$1 ||p" "$STATE" 2>/dev/null | head -1; }

fsize() { wc -c < "$1" 2>/dev/null | tr -d ' \t\r\n'; }
meta_get() { sed -n "s/^$2=//p" "$1" 2>/dev/null | head -1; }
ms_now() { awk '{ printf "%.0f\n", $1 * 1000 }' /proc/uptime; }

# ---------- 样本 ----------
sample_ok() {
    [ -s "$SAMPLE" ] || return 1
    sz=$(fsize "$SAMPLE")
    [ $((sz % PG)) -eq 0 ] || return 1
    if [ -f "$SAMPLE.meta" ]; then
        b=$(meta_get "$SAMPLE.meta" bytes)
        [ -z "$b" ] || [ "$b" = "$sz" ] || return 1
    fi
    return 0
}

export_sample() {
    [ -x "$MKCORPUS" ] || die "缺少 $MKCORPUS"
    [ -b "$SAMPLE_SRC" ] || die "$SAMPLE_SRC 不是块设备"
    want=$((SAMPLE_MB * 1024 * 1024 / PG))
    src=${SAMPLE_SRC##*/}
    mm=$(cat "/sys/block/$src/mm_stat" 2>/dev/null || true)
    if [ -n "$mm" ]; then
        set -- $mm
        avail=$(($1 / PG - $6))
        say "[样本] $src 现存非同值页 $avail ($((avail * PG / 1048576)) MiB)"
        [ "$avail" -ge "$want" ] ||
            say "       不足 ${SAMPLE_MB} MiB，样本会偏小；可先多开应用让 swap 增长再 NEW_SAMPLE=1"
    fi
    mkdir -p "$(dirname "$SAMPLE")"
    tmp="$SAMPLE.tmp"
    rm -f "$tmp" "$tmp.meta"
    part "[样本] 从 $SAMPLE_SRC 导出 $want 页 ... "
    note "[样本] 从 $SAMPLE_SRC 导出 $want 页"
    t0=$(ms_now)
    if ! out=$("$MKCORPUS" -o "$tmp" -n "$want" -i "$SAMPLE_SRC" 2>&1); then
        rm -f "$tmp"
        die "mkcorpus 失败: $out"
    fi
    note "$out"
    sz=$(fsize "$tmp")
    pages=$((sz / PG))
    if [ "$pages" -lt 16384 ]; then
        rm -f "$tmp"
        die "只导出了 $pages 页 (<64 MiB)，$src 里数据太少"
    fi
    sha=$(sha256sum "$tmp" | cut -d' ' -f1)
    {
        echo "source=$SAMPLE_SRC"
        echo "pages=$pages"
        echo "bytes=$sz"
        echo "created=$(date '+%F %T')"
        echo "kernel=$(uname -r)"
        echo "src_algo=$(sed 's/.*\[\(.*\)\].*/\1/' "/sys/block/$src/comp_algorithm" 2>/dev/null)"
        echo "src_mm_stat=$mm"
        echo "sha256=$sha"
    } > "$tmp.meta"
    chmod 600 "$tmp" "$tmp.meta"
    mv "$tmp" "$SAMPLE"
    mv "$tmp.meta" "$SAMPLE.meta"
    part "完成 ($pages 页, $(( ($(ms_now) - t0) / 1000 ))s)"; printf '\n' >&2
    note "[样本] 完成 $pages 页, $(( ($(ms_now) - t0) / 1000 ))s"
}

prepare_sample() {
    if [ "$NEW_SAMPLE" != "1" ] && sample_ok; then
        SAMPLE_STATE=复用
        return 0
    fi
    if [ "$NEW_SAMPLE" != "1" ] && [ -e "$SAMPLE" ]; then
        say "[样本] $SAMPLE 不完整（大小与 meta 不符），重新导出"
    fi
    export_sample
    SAMPLE_STATE=新导出
}

# ---------- CPU 频率 ----------
pick_freq() {   # 可用频率列表文件 目标kHz -> 最接近的可用频率
    best=$2
    bd=""
    for f in $(cat "$1" 2>/dev/null); do
        case "$f" in ''|*[!0-9]*) continue ;; esac
        d=$((f - $2)); [ "$d" -ge 0 ] || d=$((-d))
        if [ -z "$bd" ] || [ "$d" -lt "$bd" ]; then bd=$d; best=$f; fi
    done
    echo "$best"
}

lock_cpu() {
    lo=""; hi=""
    for p in /sys/devices/system/cpu/cpufreq/policy*; do
        [ -r "$p/scaling_governor" ] || continue
        echo "gov $p $(cat "$p/scaling_governor")" >> "$STATE"
        cap=$(cat "$p/cpuinfo_max_freq")
        [ -n "$lo" ] && [ "$cap" -ge "$lo" ] || lo=$cap
        [ -n "$hi" ] && [ "$cap" -le "$hi" ] || hi=$cap
    done
    cpu_locked=1
    mid=$(((lo + hi) / 2))
    FREQ_DESC=""
    for p in /sys/devices/system/cpu/cpufreq/policy*; do
        [ -r "$p/scaling_governor" ] || continue
        cap=$(cat "$p/cpuinfo_max_freq")
        if [ "$FIXED_CPU_FREQ_ENABLE" = "1" ]; then
            t=$((FIXED_BIG_FREQ_MHZ * 1000))
            [ "$lo" = "$hi" ] || [ "$cap" -gt "$mid" ] || t=$((FIXED_LITTLE_FREQ_MHZ * 1000))
            f=$(pick_freq "$p/scaling_available_frequencies" "$t")
            # 先放宽再收紧，避免 min > max 写入失败
            echo "$cap" > "$p/scaling_max_freq" 2>/dev/null || true
            echo "$f" > "$p/scaling_min_freq" 2>/dev/null || true
            echo "$f" > "$p/scaling_max_freq" 2>/dev/null || true
            FREQ_DESC="${FREQ_DESC:+$FREQ_DESC, }policy${p##*policy} $(($(cat "$p/scaling_cur_freq" 2>/dev/null || echo 0) / 1000))"
        fi
        echo performance > "$p/scaling_governor" 2>/dev/null || true
        note "  ${p##*/}: gov=$(cat "$p/scaling_governor") min=$(cat "$p/scaling_min_freq") max=$(cat "$p/scaling_max_freq")"
    done
    if [ "$FIXED_CPU_FREQ_ENABLE" = "1" ]; then
        FREQ_DESC="performance，锁定 小核 ${FIXED_LITTLE_FREQ_MHZ} / 大核 ${FIXED_BIG_FREQ_MHZ} MHz（实际 $FREQ_DESC MHz）"
    else
        FREQ_DESC="performance，未锁频"
    fi
}

restore_cpu() {   # 每个 policy：min = 最低频率，max = 最高频率，governor 恢复为测试前的
    [ "$cpu_locked" = "1" ] || return 0
    for p in /sys/devices/system/cpu/cpufreq/policy*; do
        [ -r "$p/cpuinfo_max_freq" ] || continue
        fmin=$(cat "$p/cpuinfo_min_freq"); fmax=$(cat "$p/cpuinfo_max_freq")
        echo "$fmax" > "$p/scaling_max_freq" 2>/dev/null || true
        echo "$fmin" > "$p/scaling_min_freq" 2>/dev/null || true
        echo "$fmax" > "$p/scaling_max_freq" 2>/dev/null || true
        gov=$(state_get "gov $p")
        if [ -n "$gov" ]; then echo "$gov" > "$p/scaling_governor" 2>/dev/null || true; fi
        note "  恢复 ${p##*/}: gov=$(cat "$p/scaling_governor") min=$(cat "$p/scaling_min_freq") max=$(cat "$p/scaling_max_freq")"
    done
    cpu_locked=0
}

# ---------- DDR 频率（高通 bus_dcvs）----------
# 最终 DDR 频率取所有投票的最大值，所以要把每个投票方都卡在目标值：
#   - DDR 下每个 memlat 投票节点：min = max = 目标
#   - DDR/boost_freq（下限投票）= 目标
#   - LLCC bwmon 的第二投票（投给 DDR）：second_vote_limit = 目标，否则带宽大时会把 DDR 拉高
# GPU、显示等其他投票方空闲时投票很低，一般不影响；fio 期间的实际频率会被采样记录。
# 恢复时所有投票都放开为全频段：min = hw_min_freq，max = hw_max_freq，boost_freq = 最低，
# second_vote_limit = 最高。
ddr_desc() { echo "$(($1 / 1000)) MHz (≈$(($1 * 2 / 1000)) MT/s)"; }   # kHz

lock_ddr() {
    if [ ! -r "$DDR_DIR/cur_freq" ]; then
        DDR_DIR=""
        DDR_DESC="未锁定（内核没有 bus_dcvs/DDR 接口）"
        return 0
    fi
    if [ "$FIXED_DDR_FREQ_ENABLE" != "1" ]; then
        DDR_DESC="未锁定，动态调频"
        return 0
    fi
    target=$(pick_freq "$DDR_DIR/available_frequencies" $((FIXED_DDR_MTS * 1000 / 2)))
    hwmax=$(cat "$DDR_DIR/hw_max_freq")
    echo "ddr" >> "$STATE"
    ddr_locked=1
    note "[DDR ] 目标 ${FIXED_DDR_MTS} MT/s -> $target kHz"
    for v in "$DDR_DIR"/*/min_freq; do
        v=${v%/min_freq}
        [ -f "$v/max_freq" ] || continue
        # 先放宽再收紧，避免 min > max 写入失败
        echo "$hwmax" > "$v/max_freq" 2>/dev/null || true
        echo "$target" > "$v/min_freq" 2>/dev/null || true
        echo "$target" > "$v/max_freq" 2>/dev/null || true
        note "  ${v##*/}: min=$(cat "$v/min_freq") max=$(cat "$v/max_freq")"
    done
    if [ -w "$DDR_DIR/boost_freq" ]; then
        echo "$target" > "$DDR_DIR/boost_freq" 2>/dev/null || true
    fi
    for f in "${DDR_DIR%/*}"/*/*/second_vote_limit; do
        [ -f "$f" ] || continue
        echo "$target" > "$f" 2>/dev/null || true
        note "  ${f#${DDR_DIR%/*}/}=$(cat "$f")"
    done
    sleep 0.5
    cur=$(cat "$DDR_DIR/cur_freq")
    note "  cur_freq=$cur"
    DDR_DESC="锁定 $(ddr_desc "$target")（目标 ${FIXED_DDR_MTS} MT/s）"
    [ "$cur" = "$target" ] ||
        say "[DDR ] 警告: 锁定后 cur_freq 为 $(ddr_desc "$cur")，与目标不符，可能有其他投票方"
}

restore_ddr() {   # 所有投票放开为全频段：min = 最低频率，max = 最高频率
    [ "$ddr_locked" = "1" ] || return 0
    ddr_locked=0
    [ -n "$DDR_DIR" ] && [ -r "$DDR_DIR/hw_max_freq" ] || return 0
    hwmin=$(cat "$DDR_DIR/hw_min_freq"); hwmax=$(cat "$DDR_DIR/hw_max_freq")
    for v in "$DDR_DIR"/*/min_freq; do
        v=${v%/min_freq}
        [ -f "$v/max_freq" ] || continue
        echo "$hwmax" > "$v/max_freq" 2>/dev/null || true
        echo "$hwmin" > "$v/min_freq" 2>/dev/null || true
        echo "$hwmax" > "$v/max_freq" 2>/dev/null || true
        note "  恢复 ${v##*/}: min=$(cat "$v/min_freq") max=$(cat "$v/max_freq")"
    done
    if [ -w "$DDR_DIR/boost_freq" ]; then
        echo "$hwmin" > "$DDR_DIR/boost_freq" 2>/dev/null || true
        note "  恢复 DDR/boost_freq=$(cat "$DDR_DIR/boost_freq")"
    fi
    for f in "${DDR_DIR%/*}"/*/*/second_vote_limit; do
        [ -f "$f" ] || continue
        echo "$hwmax" > "$f" 2>/dev/null || true
        note "  恢复 ${f#${DDR_DIR%/*}/}=$(cat "$f")"
    done
}

ddr_sample_start() {   # 输出文件；每 0.5 s 记录一次 DDR cur_freq (kHz)
    [ -n "$DDR_DIR" ] || return 0
    (
        trap - EXIT HUP INT TERM
        while kill -0 $$ 2>/dev/null; do
            cat "$DDR_DIR/cur_freq" || exit 0
            sleep 0.5
        done
    ) > "$1" 2>/dev/null &
    ddr_sampler=$!
}

ddr_sample_stop() {
    [ -n "$ddr_sampler" ] || return 0
    kill "$ddr_sampler" 2>/dev/null || true
    wait "$ddr_sampler" 2>/dev/null || true
    ddr_sampler=""
}

# DDR 采样文件 -> "3187" 或 "2092–3187（多数 3187）"，单位 MHz
ddr_stat() {
    awk '$1 ~ /^[0-9]+$/ {
            n[$1]++; t++
            if (min == "" || $1 + 0 < min) min = $1 + 0
            if ($1 + 0 > max) max = $1 + 0
        }
        END {
            if (!t) exit 1
            for (f in n) if (n[f] > best) { best = n[f]; mode = f }
            if (min == max) printf "%d\n", min / 1000
            else printf "%d–%d（多数 %d）\n", min / 1000, max / 1000, mode / 1000
        }' "$1" 2>/dev/null
}

# ---------- 临时 zram ----------
zdev() { if [ -b "/dev/block/zram$1" ]; then echo "/dev/block/zram$1"; else echo "/dev/zram$1"; fi; }

reserve_zram() {
    [ -r /sys/class/zram-control/hot_add ] || die "内核不支持 zram hot_add"
    bench_idx=$(cat /sys/class/zram-control/hot_add)
    bench_created=1
    case "$bench_idx" in ''|*[!0-9]*) die "hot_add 失败: $bench_idx" ;; esac
    echo "zram $bench_idx" >> "$STATE"
    i=0
    while [ ! -b "$(zdev "$bench_idx")" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
    grep -q "zram$bench_idx" /proc/swaps && die "zram$bench_idx 正被用作 swap"
    note "临时设备: $(zdev "$bench_idx")"
}

release_all() {   # 停止 fio、移除临时 zram、恢复 CPU / DDR；可重复调用
    if [ -n "$fio_pid" ]; then
        kill "$fio_pid" 2>/dev/null || true
        wait "$fio_pid" 2>/dev/null || true
        fio_pid=""
    fi
    ddr_sample_stop
    if [ -n "$bench_idx" ] && [ -d "/sys/block/zram$bench_idx" ]; then
        note ""
        note "[清理] 移除 zram$bench_idx"
        echo 1 > "/sys/block/zram$bench_idx/reset" 2>/dev/null || true
        if [ "$bench_created" = "1" ]; then
            echo "$bench_idx" > /sys/class/zram-control/hot_remove 2>/dev/null || true
        fi
        [ ! -d "/sys/block/zram$bench_idx" ] || say "警告: zram$bench_idx 未能移除"
    fi
    bench_idx=""
    if [ "$ddr_locked$cpu_locked" != "00" ]; then
        note "[清理] CPU / DDR 恢复为全频段"
        restore_ddr
        restore_cpu
    fi
    rm -f "$STATE"
}

cleanup() {
    rc=$?
    trap - EXIT
    trap '' HUP INT TERM   # 清理过程中再来信号（比如 stop 又发了 TERM）也不能打断
    set +e
    if [ "$rc" = 130 ]; then printf '\n' >&2; say "[清理] 测试被中断，正在恢复设备状态"; fi
    release_all
    [ "$rc" != 130 ] || say "[清理] 已恢复：临时 zram 已移除，CPU / DDR 已恢复为全频段"
    exit "$rc"
}

bench_alive() {   # 状态文件里的测试进程是否还在运行
    p=$(state_get pid)
    [ -n "$p" ] && kill -0 "$p" 2>/dev/null && grep -q zram-bench "/proc/$p/cmdline" 2>/dev/null
}

restore_state() {   # 按状态文件恢复；没有状态文件时只把 CPU / DDR 恢复为全频段
    if [ ! -f "$STATE" ]; then
        say "[恢复] 没有上次测试的状态记录，只把 CPU / DDR 恢复为全频段（governor 不变）"
    fi
    pkill -f "$FIO --readonly" 2>/dev/null && sleep 1 || true   # 残留的 fio 会占住 zram
    bench_idx=$(state_get zram)
    if [ -n "$bench_idx" ] && grep -q "zram$bench_idx " /proc/swaps; then
        bench_idx=""   # 已被当作 swap 使用，不是我们的临时设备
    fi
    bench_created=1
    cpu_locked=1
    ddr_locked=1
    release_all
    say "[恢复] 完成：临时 zram 已移除，CPU / DDR 已恢复为全频段"
}

stop_bench() {   # 通知正在运行的测试退出（它会自己恢复）；超时或进程已不在则直接恢复
    if [ ! -f "$STATE" ]; then
        say "[停止] 没有正在运行的测试"
        return 0
    fi
    if bench_alive; then
        p=$(state_get pid)
        say "[停止] 通知测试进程 $p 退出并恢复设备状态"
        kill -TERM "$p" 2>/dev/null || true
        i=0
        while [ -f "$STATE" ] && bench_alive && [ "$i" -lt 150 ]; do sleep 0.2; i=$((i + 1)); done
        if [ ! -f "$STATE" ]; then
            say "[停止] 完成：临时 zram 已移除，CPU / DDR 已恢复为全频段"
            return 0
        fi
        kill -KILL "$p" 2>/dev/null || true
    fi
    restore_state
}

sddc_pending() { awk -F: '$1 == "pending" { gsub(/[ \t]/, "", $2); print $2 }' "$1" 2>/dev/null; }

wait_pending() {   # sysfs 目录；有 sddc_stat 时等 pending 清零，终端显示 "pending N"
    st="$1/sddc_stat"
    [ -r "$st" ] || return 0
    p0=$(sddc_pending "$st")
    part " → pending ${p0:-?}"
    t0=$(ms_now)
    i=0
    while [ "$i" -lt 600 ]; do
        if [ "$(sddc_pending "$st")" = "0" ]; then
            sleep "$(awk -v ms="$SDDC_IDLE_GRACE_MS" 'BEGIN { printf "%.3f", ms / 1000 }')"
            if [ "$(sddc_pending "$st")" = "0" ]; then
                note "  pending  ${p0:-?} → 0, $(($(ms_now) - t0)) ms (含 ${SDDC_IDLE_GRACE_MS} ms 余量)"
                return 0
            fi
        fi
        sleep 0.1
        i=$((i + 1))
    done
    printf '\n' >&2
    say "  警告: pending 60 秒内未清零（当前 $(sddc_pending "$st")）"
}

bench_algo() {   # algo resultdir
    a=$1; out=$2
    sys=/sys/block/zram$bench_idx
    dev=$(zdev "$bench_idx")
    mkdir -p "$out"
    echo 1 > "$sys/reset"
    echo "$a" > "$sys/comp_algorithm" 2>/dev/null || die "设置算法 $a 失败"
    echo "$SAMPLE_BYTES" > "$sys/disksize" || die "设置 disksize 失败"

    note "  设备     $dev, disksize $SAMPLE_BYTES"

    part "写入"
    t0=$(ms_now)
    if ! dd_out=$(dd if="$SAMPLE" of="$dev" bs=4k oflag=direct 2>&1); then
        note "  dd 不支持 oflag=direct（$(echo "$dd_out" | tail -1)），改用缓冲写"
        dd_out=$(dd if="$SAMPLE" of="$dev" bs=4k 2>&1) || die "写入 $dev 失败: $(echo "$dd_out" | tail -1)"
    fi
    ms=$(($(ms_now) - t0)); [ "$ms" -gt 0 ] || ms=1
    echo "$ms" > "$out/write-elapsed-ms"
    awk -v b="$SAMPLE_BYTES" -v ms="$ms" 'BEGIN { printf "%.1f\n", b / 1048576 * 1000 / ms }' > "$out/write-mib-s"
    note "  写入     $ms ms, $(cat "$out/write-mib-s") MiB/s"

    wait_pending "$sys"
    cat "$sys/mm_stat" > "$out/mm_stat"
    [ -r "$sys/sddc_stat" ] && cat "$sys/sddc_stat" > "$out/sddc_stat"
    note "  mm_stat  $(cat "$out/mm_stat")"
    set -- $(cat "$out/mm_stat")
    awk -v a="$1" -v b="$2" 'BEGIN { printf "%.4f\n", (b > 0 ? a / b : 0) }' > "$out/compratio"
    awk -v a="$1" -v b="$3" 'BEGIN { printf "%.4f\n", (b > 0 ? a / b : 0) }' > "$out/physical-ratio"
    note "  比率     $(cat "$out/compratio") (phys $(cat "$out/physical-ratio"))"
    part " → 比率 $(cut -c1-5 "$out/compratio") → 读"
    ddr_sample_start "$out/ddr-khz"

    for o in $IO_ORDERS; do
        bs=$((4 << o))k
        part " $((4 << o))K"
        note "  fio      bs=$bs"
        # 后台运行再 wait：收到 INT/TERM 时能立即进入清理，而不是等这一档跑完
        "$FIO" --readonly --name=randread --filename="$dev" --direct=1 --rw=randread \
            --ioengine=psync --randrepeat=0 --bs="$bs" --numjobs="$FIO_JOBS" --iodepth=1 \
            --group_reporting=1 --time_based=1 --runtime="$FIO_RUNTIME" \
            --output-format=json --output="$out/pc-$o.json" >> "$LOG" 2>&1 &
        fio_pid=$!
        wait "$fio_pid" || { fio_pid=""; die "fio 失败（bs=$bs），见 $LOG"; }
        fio_pid=""
        sleep 1
    done
    ddr_sample_stop
    ddr=$(ddr_stat "$out/ddr-khz") && note "  DDR      fio 期间 $ddr MHz"
    echo 1 > "$sys/reset"
}

# ---------- 汇总 ----------
# fio JSON -> "MiB/s IOPS mean p50 p90 p99 p99.9"（延迟单位 ns）
fio_vals() {
    awk '
        /"read" : \{/  { r = 1; next }
        /"write" : \{/ { r = 0 }
        !r { next }
        { gsub(/[",]/, "") }
        $1 == "bw_bytes" { bw = $3 }
        $1 == "iops"     { iops = $3 }
        $1 == "clat_ns"  { c = 1 }
        $1 == "lat_ns"   { c = 0 }
        c && $1 == "mean"      { mean = $3 }
        c && $1 == "50.000000" { p50 = $3 }
        c && $1 == "90.000000" { p90 = $3 }
        c && $1 == "99.000000" { p99 = $3 }
        c && $1 == "99.900000" { p999 = $3 }
        END {
            if (bw == "") exit 1
            printf "%.1f %.0f %.0f %s %s %s %s\n", bw / 1048576, iops, mean, p50, p90, p99, p999
        }' "$1" 2>/dev/null
}

sddc_val() { awk -F: -v k="$2" '$1 == k { gsub(/[ \t]/, "", $2); print $2 }' "$1" 2>/dev/null; }

write_csv() {   # dir algos orders
    dir=$1; algos=$2; orders=$3
    {
        echo "algo,payload-ratio,physical-ratio,write-MiB-s,orig-bytes,compressed-bytes,mem-used-bytes,sddc-aliases,sddc-deltas"
        for a in $algos; do
            set -- $(cat "$dir/$a/mm_stat")
            echo "$a,$(cat "$dir/$a/compratio"),$(cat "$dir/$a/physical-ratio"),$(cat "$dir/$a/write-mib-s"),$1,$2,$3,$(sddc_val "$dir/$a/sddc_stat" aliases),$(sddc_val "$dir/$a/sddc_stat" deltas)"
        done
    } > "$dir/compression.csv"
    {
        echo "algo,bs,MiB-s,IOPS,mean-ns,p50-ns,p90-ns,p99-ns,p99.9-ns"
        for a in $algos; do
            for o in $orders; do
                v=$(fio_vals "$dir/$a/pc-$o.json") || continue
                echo "$a,$((4 << o))K,$(echo "$v" | tr ' ' ',')"
            done
        done
    } > "$dir/read-speed.csv"
}

print_summary() {
    dir=$1
    [ -d "$dir" ] || die "没有结果目录 $dir"
    info=$dir/info
    algos=$(meta_get "$info" algos)
    if [ -z "$algos" ]; then        # 旧格式结果目录
        for x in "$dir"/*/mm_stat; do [ -f "$x" ] && algos="$algos $(basename "$(dirname "$x")")"; done
    fi
    [ -n "${algos# }" ] || die "$dir 里没有算法结果"
    first=""
    for a in $algos; do first=$a; break; done
    orders=$(cd "$dir/$first" && ls pc-*.json 2>/dev/null | sed 's/pc-\([0-9]*\)\.json/\1/' | sort -n | tr '\n' ' ')
    base=$(meta_get "$info" baseline)
    if [ -z "$base" ]; then
        base=$first
        for a in $algos; do [ "$a" = "lz4" ] && base=lz4; done
    fi

    echo
    echo "══════ zram bench $(basename "$dir") ══════"
    echo "测试条件"
    if [ -f "$info" ]; then
        echo "  内核  $(meta_get "$info" kernel)"
        echo "  CPU   $(meta_get "$info" freq)"
        ddr_info=$(meta_get "$info" ddr)
        [ -z "$ddr_info" ] || echo "  DDR   $ddr_info"
        m=""
        for a in $algos; do
            v=$(ddr_stat "$dir/$a/ddr-khz") && m="${m:+$m, }$a $v"
        done
        [ -z "$m" ] || echo "        fio 期间实测: $m MHz"
        echo "  fio   随机读 psync direct，每档 $(meta_get "$info" fio_runtime)s × $(meta_get "$info" fio_jobs) jobs"
        echo "  样本  $(meta_get "$info" sample) ($(meta_get "$info" sample_desc))"
    else
        echo "  样本  $(head -1 "$dir/dataset.meta" 2>/dev/null)"
    fi

    echo
    echo "压缩（pending 清零后的 mm_stat）"
    printf '  %-10s %7s %7s %8s %14s\n' algo ratio phys "wr MiB/s" "sddc al/delta"
    for a in $algos; do
        [ -f "$dir/$a/mm_stat" ] || continue
        al=$(sddc_val "$dir/$a/sddc_stat" aliases); de=$(sddc_val "$dir/$a/sddc_stat" deltas)
        s="-"; [ "${al:-0}${de:-0}" = "00" ] || s="${al:-0}/${de:-0}"
        printf '  %-10s %7.3f %7.3f %8.1f %14s\n' "$a" "$(cat "$dir/$a/compratio")" \
            "$(cat "$dir/$a/physical-ratio")" "$(cat "$dir/$a/write-mib-s" 2>/dev/null || echo 0)" "$s"
    done

    tmp=$dir/.summary.tmp
    for a in $algos; do
        for o in $orders; do
            v=$(fio_vals "$dir/$a/pc-$o.json") && echo "$a $o $v" >> "$tmp"
        done
    done
    lo=""; for o in $orders; do lo=$o; break; done
    awk -v algos="$algos" -v orders="$orders" -v base="$base" -v lo="$lo" '
        { bw[$1 " " $2] = $3
          if ($2 == lo) lat[$1] = sprintf(" %7.2f %7.2f %7.2f %7.2f %7.2f", $5/1000, $6/1000, $7/1000, $8/1000, $9/1000) }
        END {
            na = split(algos, A, " "); no = split(orders, O, " ")
            if (na > 1) printf "\n随机读吞吐 MiB/s（百分比相对 %s）\n", base
            else printf "\n随机读吞吐 MiB/s\n"
            printf "  %-10s", "algo"
            for (j = 1; j <= no; j++) printf " %8s", (4 * 2 ^ O[j]) "K"
            printf "\n"
            for (i = 1; i <= na; i++) {
                printf "  %-10s", A[i]
                for (j = 1; j <= no; j++) {
                    k = A[i] " " O[j]
                    if (k in bw) printf " %8.0f", bw[k]; else printf " %8s", "-"
                }
                printf "\n"
                if (A[i] == base || na < 2) continue
                printf "  %-10s", ""
                for (j = 1; j <= no; j++) {
                    k = A[i] " " O[j]; b = base " " O[j]
                    if ((k in bw) && (b in bw) && bw[b] > 0) printf " %+7.1f%%", (bw[k] / bw[b] - 1) * 100
                    else printf " %8s", ""
                }
                printf "\n"
            }
            if (lo == "") exit
            printf "\n%sK 读延迟 µs\n", 4 * 2 ^ lo
            printf "  %-10s %7s %7s %7s %7s %7s\n", "algo", "mean", "p50", "p90", "p99", "p99.9"
            for (i = 1; i <= na; i++) if (A[i] in lat) printf "  %-10s%s\n", A[i], lat[A[i]]
        }' "$tmp"
    rm -f "$tmp"
    echo
    echo "结果  $dir"
    return 0
}

# ---------- 主流程 ----------
run_bench() {
    [ "$(id -u)" = "0" ] || die "需要 root"
    [ -x "$FIO" ] || die "缺少 $FIO"
    avail_algos=$(tr -d '[]' < /sys/block/zram0/comp_algorithm)
    for a in $ALGOS; do
        case " $avail_algos " in *" $a "*) ;; *) die "内核不支持算法 $a（可用: $avail_algos）。用 ALGOS=\"算法 ...\" 或主机脚本参数指定要测的算法" ;; esac
    done
    if [ -z "$BASELINE" ]; then
        for a in $ALGOS; do BASELINE=$a; break; done
        case " $ALGOS " in *" lz4 "*) BASELINE=lz4 ;; esac
    fi

    RESULT_DIR=${RESULT_DIR:-$D/results/$(date +%Y%m%d-%H%M%S)}
    mkdir -p "$RESULT_DIR"
    LOG=$RESULT_DIR/run.log
    : > "$LOG"

    prepare_sample
    SAMPLE_BYTES=$(fsize "$SAMPLE")
    pages=$((SAMPLE_BYTES / PG))
    sha=$(meta_get "$SAMPLE.meta" sha256)
    desc="$((SAMPLE_BYTES / 1048576)) MiB, $pages 页, $SAMPLE_STATE"
    [ -z "$sha" ] || desc="$desc, sha $(echo "$sha" | cut -c1-8)"
    created=$(meta_get "$SAMPLE.meta" created)
    [ -z "$created" ] || desc="$desc, 导出于 $created"
    say "[样本] ${SAMPLE#$D/} ($desc)"
    cp "$SAMPLE.meta" "$RESULT_DIR/dataset.meta" 2>/dev/null || true

    if [ -f "$STATE" ]; then
        bench_alive && die "已有测试在运行（pid $(state_get pid)）；要停止请运行 sh zram-bench.sh stop"
        say "[恢复] 上次测试没有正常结束，先恢复设备状态"
        restore_state
    fi
    trap cleanup EXIT
    trap 'exit 130' HUP INT TERM
    echo "pid $$" > "$STATE"
    lock_cpu
    lock_ddr
    reserve_zram
    {
        echo "algos=$(echo $ALGOS)"
        echo "baseline=$BASELINE"
        echo "kernel=$(uname -r)"
        echo "freq=$FREQ_DESC"
        echo "ddr=$DDR_DESC"
        echo "fio_runtime=$FIO_RUNTIME"
        echo "fio_jobs=$FIO_JOBS"
        echo "sample=${SAMPLE#$D/}"
        echo "sample_desc=$desc"
        echo "date=$(date '+%F %T')"
    } > "$RESULT_DIR/info"
    say "[CPU ] $FREQ_DESC"
    say "[DDR ] $DDR_DESC"
    say "[fio ] ${FIO_RUNTIME}s × $FIO_JOBS jobs，块大小:$(for o in $IO_ORDERS; do printf ' %sK' $((4 << o)); done)"

    n=0; total=$(echo $ALGOS | wc -w)
    # 每档 fio = 运行时间 + 约 2 s（启动 + 间隔）；写入 + pending 约 15 s
    per=$(( $(echo $IO_ORDERS | wc -w) * (FIO_RUNTIME + 2) + 15 ))
    say "[预计] 每个算法约 $(awk -v s="$per" 'BEGIN { printf "%.1f", s / 60 }') 分钟，$total 个共约 $(awk -v s="$((per * total))" 'BEGIN { printf "%.0f", s / 60 + 0.5 }') 分钟，请耐心等待"
    for a in $ALGOS; do
        n=$((n + 1))
        part "[$n/$total] $a: "
        note ""
        note "[$n/$total] $a"
        bench_algo "$a" "$RESULT_DIR/$a"
        part " ✓"; printf '\n' >&2
        note "  完成"
    done
    release_all
    write_csv "$RESULT_DIR" "$ALGOS" "$IO_ORDERS"
    print_summary "$RESULT_DIR" | tee "$RESULT_DIR/summary.txt"
}

case "${1:-run}" in
    run)
        run_bench
        ;;
    sample)
        [ "$(id -u)" = "0" ] || die "需要 root"
        prepare_sample
        say "[样本] ${SAMPLE#$D/} ($SAMPLE_STATE, $(($(fsize "$SAMPLE") / PG)) 页)"
        ;;
    stop)
        [ "$(id -u)" = "0" ] || die "需要 root"
        stop_bench
        ;;
    restore)
        [ "$(id -u)" = "0" ] || die "需要 root"
        if bench_alive; then die "测试仍在运行（pid $(state_get pid)），请用 sh zram-bench.sh stop"; fi
        restore_state
        ;;
    summary)
        dir=${2:-$(ls -d "$D"/results/*/ 2>/dev/null | sort | tail -1)}
        print_summary "${dir%/}"
        ;;
    -h|--help|help)
        awk 'NR > 1 && !/^#/ { exit } NR > 1 { sub(/^# ?/, ""); print }' "$0"
        ;;
    *)
        die "未知命令 $1（run | sample | summary [DIR] | stop | restore）"
        ;;
esac
