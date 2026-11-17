# zram-bench

在 Android 设备上比较 zram 压缩算法的基准测试脚本。

用设备 `zram0` 里真实换出的内存页做样本，在一个临时 zram 设备上逐个算法测试
**压缩比**和 **fio 随机读吞吐 / 延迟**，结果输出为终端汇总和 CSV。

- 样本取自真实 swap 数据，跳过空 slot 和同值页，每一页都会经过压缩器
- 测试用 hot-add 的临时 zramN，不动系统正在用的 zram0
- 测试期间锁定 CPU 和 DDR 频率，并记录 fio 期间的实际 DDR 频率
- 退出（包括 Ctrl-C、出错）时自动停止 fio、移除临时设备，CPU / DDR 恢复为全频段
- 一条命令完成：推送 → 设备上跑测 → 拉回结果

> [!IMPORTANT]
> 默认算法列表里的 **`lz4kds` 是作者自己内核特有的算法，官方 / 上游内核以及各厂商的内核都没有。**
> 在你的设备上请改测内核支持的算法，例如 `./run-zram-bench.sh lz4 zstd`，
> 方法见[添加 / 删除压缩算法](#添加--删除压缩算法)。

> [!WARNING]
> **生成的样本含有个人隐私，不要外传。** 样本是 zram0 里其他应用的内存内容，
> 可能包含密码、聊天记录、密钥等，详见[样本](#样本)。

## 环境要求

设备：

- arm64 Android，已 root（`adb root` 或 `su` 均可）
- 内核支持 zram hot_add（存在 `/sys/class/zram-control/hot_add`）
- `zram0` 已作为 swap 使用且存有足够数据（默认样本 512 MiB，至少需要 64 MiB）
- `/data/local/tmp` 有样本大小 + 结果的剩余空间
- DDR 锁频只支持高通平台（`/sys/devices/system/cpu/bus_dcvs`），其他平台会跳过 DDR 锁频，其余照常

主机：

- bash、adb

## 快速开始

```sh
git clone https://github.com/whitewhale0612/zram-bench.git
cd zram-bench
./run-zram-bench.sh lz4 zstd   # 指定要测的算法（推荐）
./run-zram-bench.sh            # 测默认算法 lz4kds lz4（仅作者内核可用）
```

第一次运行会在设备上从 zram0 导出样本，之后的运行都复用这份样本。
结果拉回到本机 `results/<时间>/`，终端最后打印汇总。

> [!NOTE]
> **一次完整测试需要几分钟，默认参数下每个算法约 2.5 分钟，请耐心等待。**
> 测试过程中除了每个算法一行进度外没有其他输出，属于正常现象，不要中断。
> 详见[测试耗时](#测试耗时)。

## 测试耗时

每个算法的耗时 ≈ 写入和 pending（约 5～15 s）+ 档位数 × (`FIO_RUNTIME` + 约 2 s)。

| 参数 | 每个算法 | 2 个算法 | 3 个算法 |
| --- | --- | --- | --- |
| 默认（4 档 × 30 s） | 约 2.5 分钟 | 约 5 分钟 | 约 7.5 分钟 |
| `FIO_RUNTIME=10` | 约 1 分钟 | 约 2 分钟 | 约 3 分钟 |
| `FIO_RUNTIME=10 IO_ORDERS="0"`（只测 4K） | 约 20 秒 | 约 40 秒 | 约 1 分钟 |

另外：

- 第一次运行（或 `NEW_SAMPLE=1`）要从 zram0 导出样本，需要扫描整个 zram0，通常几十秒，zram0 越大越久。
- 本机样本推送到设备时，512 MiB 通过 USB 约需十几秒到半分钟。
- 跑测开始前终端会打印 `[预计]` 一行，按当前参数给出预计时间。

调试脚本或快速看趋势时可以用较短的 `FIO_RUNTIME`；正式对比建议用默认的 30 s，结果更稳定。

## 用法

### 主机侧：`run-zram-bench.sh`

推送脚本和二进制到设备的 `/data/local/tmp/zram-bench-package`，在设备上运行
`zram-bench.sh`，再把结果拉回本机。

```sh
./run-zram-bench.sh                       # 默认算法
./run-zram-bench.sh lz4kds lz4 zstd       # 位置参数 = 要测的算法
FIO_RUNTIME=10 ./run-zram-bench.sh        # 环境变量原样传给设备脚本
NEW_SAMPLE=1 ./run-zram-bench.sh          # 设备上从 zram0 重新导出样本
PULL_SAMPLE=1 ./run-zram-bench.sh         # 跑完把设备上的样本也拉回 samples/
```

多台设备时用 `ANDROID_SERIAL=<序列号> ./run-zram-bench.sh` 选择设备。

### 设备侧：`zram-bench.sh`

也可以直接在设备的 root shell 里运行：

```sh
cd /data/local/tmp/zram-bench-package
sh zram-bench.sh                          # 准备样本 + 跑测 + 打印汇总
ALGOS="lz4 zstd" sh zram-bench.sh         # 指定算法
FIO_RUNTIME=10 IO_ORDERS="0 2" sh zram-bench.sh   # 每档 10 s，只测 4K 和 16K
sh zram-bench.sh sample                   # 只准备样本
NEW_SAMPLE=1 sh zram-bench.sh sample      # 从 zram0 重新导出样本
sh zram-bench.sh summary                  # 重新打印最近一次的汇总
sh zram-bench.sh summary results/<时间>    # 重新打印指定一次的汇总
sh zram-bench.sh stop                     # 停止正在运行的测试并恢复设备状态
sh zram-bench.sh restore                  # 测试被 kill -9 等强制结束后手动恢复
sh zram-bench.sh --help                   # 查看全部参数
```

## 添加 / 删除压缩算法

要测哪些算法由 `ALGOS` 决定，空格分隔。按需选一种方式：

| 方式 | 写法 | 作用范围 |
| --- | --- | --- |
| 主机脚本位置参数 | `./run-zram-bench.sh lz4 zstd lzo-rle` | 本次运行 |
| 环境变量 | `ALGOS="lz4 zstd" sh zram-bench.sh` | 本次运行 |
| 改默认值 | 编辑 [zram-bench.sh](zram-bench.sh) 中的 `ALGOS=${ALGOS:-lz4kds lz4}` 一行 | 以后每次 |

注意：

- **只能测内核支持的算法。** 先在设备上查看可用列表：

  ```sh
  adb shell cat /sys/block/zram0/comp_algorithm
  # lzo lzo-rle lz4 [lz4kds] zstd     方括号是 zram0 当前在用的算法
  ```

  `ALGOS` 里有内核不支持的算法时，脚本在开始前就会报错并列出可用算法。
  要增加内核里没有的算法，需要在内核里打开对应的 crypto / zram 后端配置（如
  `CONFIG_CRYPTO_ZSTD`），这不在本脚本范围内。
- **默认列表 `lz4kds lz4` 中的 `lz4kds` 是作者内核特有的算法，官方内核没有。**
  在其他内核上直接运行会报“内核不支持算法 lz4kds”，请用上面任一方式改成你的内核支持的算法。
  汇总里的 `sddc al/delta` 列和进度中的 `pending` 也只在提供 `sddc_stat` 的内核上才有数据，其他内核显示 `-` 或不显示。
- 汇总里的百分比是相对基准算法的差值。基准默认为 `lz4`（若在列表中），否则为列表第一个；
  用 `BASELINE=zstd` 指定其他算法。
- 算法按 `ALGOS` 的顺序依次测试，每增加一个算法，耗时增加一份（见[测试耗时](#测试耗时)）。

## 测试条件：CPU 与 DDR 频率

zram 读性能同时受 CPU（解压）和内存带宽影响，而 CPU、DDR 默认都会随负载动态调频，
不同算法的负载不同，调到的频率也不同，比较就不公平。所以测试期间两者都锁定。
锁定的条件会打印在终端开头和汇总的“测试条件”中，并写入结果目录的 `info`。

### CPU

- 所有 cpufreq policy 的 governor 设为 `performance`。
- 小核锁定到 `FIXED_LITTLE_FREQ_MHZ`（默认 1552 MHz），大核锁定到 `FIXED_BIG_FREQ_MHZ`（默认 1689 MHz），
  取 `scaling_available_frequencies` 中最接近的档位。`cpuinfo_max_freq` 高于各 policy 最高与最低值中点的算大核，其余算小核。
- 汇总中“实际”是锁定后各 policy 的 `scaling_cur_freq`。
- `FIXED_CPU_FREQ_ENABLE=0`：只设 governor，不锁频。

### DDR

- 默认锁定到 `FIXED_DDR_MTS=6389` MT/s 附近的档位。DDR 频率 = 数据速率 / 2，
  取 `bus_dcvs/DDR/available_frequencies` 中最接近的一档，例如 SM8750 上是 **3187 MHz（≈6374 MT/s）**。
- DDR 的最终频率取所有投票的最大值，脚本把以下投票都卡在目标值：
  - `bus_dcvs/DDR/` 下每个 memlat 投票节点的 `min_freq` 和 `max_freq`
  - `bus_dcvs/DDR/boost_freq`
  - `bus_dcvs/LLCC/*bwmon*/second_vote_limit`（LLCC 带宽监控给 DDR 的第二投票；
    不限制它的话，读带宽大时 DDR 会被拉到 3686～4761 MHz）
- fio 期间每 0.5 s 采样一次 `DDR/cur_freq`，汇总中“fio 期间实测”就是采样结果。
  如果显示成 `3187–4761（多数 3187）` 这样的范围，说明还有其他投票方把 DDR 拉高，结果要谨慎对待。
- `FIXED_DDR_FREQ_ENABLE=0`：不锁 DDR，但仍然记录实际频率。
- 非高通平台（没有 `bus_dcvs`）会显示“未锁定”，不影响其他测试。

默认锁频值是在 SM8750 上选的。换平台时请按设备的可用频率调整：

```sh
adb shell cat /sys/devices/system/cpu/cpufreq/policy*/scaling_available_frequencies
adb shell cat /sys/devices/system/cpu/bus_dcvs/DDR/available_frequencies   # 单位 kHz
```

### 测试结束后的恢复

无论正常结束、Ctrl-C 还是出错，脚本退出时都会把锁定的频率**放开为全频段**，而不是写回测试前的值
（测试前的值往往是系统临时设置的）：

| 项目 | 恢复为 |
| --- | --- |
| CPU 每个 policy | `scaling_min_freq` = `cpuinfo_min_freq`（最低），`scaling_max_freq` = `cpuinfo_max_freq`（最高） |
| CPU governor | 测试前的 governor（如 `walt`、`schedutil`） |
| DDR memlat 投票节点 | `min_freq` = `hw_min_freq`（最低），`max_freq` = `hw_max_freq`（最高） |
| `DDR/boost_freq` | `hw_min_freq`（最低，即不额外抬高） |
| LLCC bwmon `second_vote_limit` | `hw_max_freq`（最高，即不限制） |
| 临时 zramN | 先停止 fio，再 reset 并 hot_remove |

恢复的每一步和读回的值都记录在 `run.log` 末尾的 `[清理]` 部分。

> [!NOTE]
> 恢复后读回的 CPU `scaling_max_freq` 可能低于 `cpuinfo_max_freq`。这是系统自己的功耗 / 温控策略
> 另外设置的上限（内核取所有上限请求中最小的一个），不是脚本残留；系统会按自己的策略继续调整。

## 参数

均为环境变量，括号内为默认值。在主机上设置的会自动传给设备脚本。

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `ALGOS` | `lz4kds lz4` | 要测的算法，见[添加 / 删除压缩算法](#添加--删除压缩算法) |
| `BASELINE` | `lz4` 或第一个算法 | 汇总百分比的对比基准 |
| `SAMPLE_MB` | `512` | 样本大小（MiB） |
| `SAMPLE` | `samples/zram0-<MB>M.bin` | 使用指定的样本文件 |
| `NEW_SAMPLE` | `0` | `1` = 忽略已有样本，从 zram0 重新导出 |
| `IO_ORDERS` | `0 1 2 3` | fio 块大小档位，`n` 表示 4K × 2ⁿ（即 4K/8K/16K/32K） |
| `FIO_RUNTIME` | `30` | 每档读测试的秒数 |
| `FIO_JOBS` | CPU 核数 | fio 并发线程数 |
| `FIXED_CPU_FREQ_ENABLE` | `1` | `0` = 只设 performance governor，不锁频 |
| `FIXED_LITTLE_FREQ_MHZ` | `1552` | 小核锁定频率（取最接近的可用频点） |
| `FIXED_BIG_FREQ_MHZ` | `1689` | 大核锁定频率（取最接近的可用频点） |
| `FIXED_DDR_FREQ_ENABLE` | `1` | `0` = DDR 不锁频（仍记录实际频率） |
| `FIXED_DDR_MTS` | `6389` | DDR 目标数据速率 MT/s，取最接近的档位 |
| `SDDC_IDLE_GRACE_MS` | `2000` | pending 清零后再等待的毫秒数 |
| `RESULT_DIR` | `results/<时间>` | 结果目录 |

只在主机脚本中使用：

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `DEV_DIR` | `/data/local/tmp/zram-bench-package` | 设备上的工作目录 |
| `SKIP_PUSH` | `0` | `1` = 不推送脚本和二进制（设备上已有） |
| `PULL` | `1` | `0` = 不拉回结果 |
| `PULL_SAMPLE` | `0` | `1` = 把设备上的样本拉回本机 `samples/` |

## 测试流程

1. 检查 `ALGOS` 中的算法内核都支持。
2. 准备样本：已有就复用，否则从 zram0 导出。
3. 锁定 CPU 和 DDR 频率（见[测试条件](#测试条件cpu-与-ddr-频率)）。
4. hot-add 一个临时 zramN，`disksize` = 样本大小，保证每个 slot 都有数据。对每个算法：
   1. reset → 设置算法 → `dd` 4K 写入整个样本（dd 支持时用 `oflag=direct`，toybox dd 不支持则用缓冲写）
   2. 内核提供 `sddc_stat` 时，等其中的 pending 清零后再等 `SDDC_IDLE_GRACE_MS`
   3. 记录 `mm_stat`（和 `sddc_stat`），计算压缩比
   4. fio 随机读（psync, direct）依次测各块大小，同时采样 DDR 频率
5. 退出时（包括 Ctrl-C、出错）停止 fio、移除 zramN，CPU / DDR 恢复为全频段，governor 恢复为测试前的
   （见[测试结束后的恢复](#测试结束后的恢复)）。

## 样本

样本从 `/dev/block/zram0` 导出系统真正换出过的页：

- 跳过空 slot（读出来全零）和同值页（zram 不经过压缩器），样本中每一页都会走压缩器。
- 页均匀取自整个 zram0。zram0 中数据不够时样本会偏小，少于 64 MiB 直接报错；
  可以先多开几个应用让 swap 增长，再用 `NEW_SAMPLE=1` 重新导出。
- 先写到 `.tmp` 文件，完成后才改名，中断不会留下不完整的样本。
- 同名 `.meta` 记录页数、字节数、导出时间、内核版本、zram0 当时的算法和 `mm_stat`、sha256。
  样本大小与 meta 一致就复用。
- 设备上没有样本而本机 `samples/` 有时，主机脚本会把本机样本推到设备上复用。

> [!WARNING]
> **样本涉及个人隐私，不要外传。**
>
> 样本是设备上其他应用的内存内容，可能包含密码、聊天记录、密钥、浏览记录等。
>
> - 不要上传、提交到 git、附在 issue 里，也不要发给任何人（`.bin` 和 `.meta` 都不要）。
> - 文件权限为 0600，`samples/` 已在 `.gitignore` 中；用 `PULL_SAMPLE=1` 拉回本机时同样要妥善保管。
> - 测试完不再需要时请删除：`adb shell su -c rm -r /data/local/tmp/zram-bench-package/samples`
> - 结果目录 `results/` 只含统计数据和 fio 输出，不含页面内容，可以分享。

## 输出

### 进度

开头打印测试条件和预计时间，之后每个算法一行：

```
[样本] samples/zram0-512M.bin (512 MiB, 131072 页, 复用, sha 3338bde5, 导出于 2026-11-18 00:50:35)
[CPU ] performance，锁定 小核 1552 / 大核 1689 MHz（实际 policy0 1555, policy6 1689 MHz）
[DDR ] 锁定 3187 MHz (≈6374 MT/s)（目标 6389 MT/s）
[fio ] 30s × 8 jobs，块大小: 4K 8K 16K 32K
[预计] 每个算法约 2.4 分钟，2 个共约 5 分钟，请耐心等待
[1/2] lz4kds: 写入 → pending 0 → 比率 3.851 → 读 4K 8K 16K 32K ✓
[2/2] lz4: 写入 → pending 0 → 比率 2.788 → 读 4K 8K 16K 32K ✓
```

`pending N` 是写入完成时 `sddc_stat` 里的 pending 数，脚本等它清零后才记录压缩结果；
内核没有 `sddc_stat` 时不显示这一步。

### 汇总

最后打印汇总，同时保存为 `summary.txt`（下例为 `FIO_RUNTIME=5 IO_ORDERS="0 3"` 的快速测试）：

```
══════ zram bench 20261118-011423 ══════
测试条件
  内核  6.6.118
  CPU   performance，锁定 小核 1552 / 大核 1689 MHz（实际 policy0 1555, policy6 1689 MHz）
  DDR   锁定 3187 MHz (≈6374 MT/s)（目标 6389 MT/s）
        fio 期间实测: lz4kds 3187, lz4 3187 MHz
  fio   随机读 psync direct，每档 5s × 8 jobs
  样本  samples/zram0-512M.bin (512 MiB, 131072 页, 复用, sha 3338bde5, 导出于 2026-11-18 00:50:35)

压缩（pending 清零后的 mm_stat）
  algo         ratio    phys wr MiB/s  sddc al/delta
  lz4kds       3.852   3.732    147.1    11948/24707
  lz4          2.788   2.708    198.4              -

随机读吞吐 MiB/s（百分比相对 lz4）
  algo             4K      32K
  lz4kds         4485     6076
                -9.1%    -9.9%
  lz4            4932     6747

4K 读延迟 µs
  algo          mean     p50     p90     p99   p99.9
  lz4kds        6.39    5.60    8.90   12.22   80.38
  lz4           5.76    5.34    7.52   10.18   60.67
```

- `ratio` = orig_data_size / compr_data_size；`phys` = orig_data_size / mem_used_total（含 zsmalloc 碎片）。
- `wr MiB/s` 是 dd 写入速度，波动很大，不适合用来比较算法；比较请看读吞吐和延迟。
- `sddc al/delta` 是 `sddc_stat` 中的 aliases / deltas，没有则显示 `-`。
- 百分比行是该算法相对基准算法（`BASELINE`）的读吞吐差。
- 只有测试条件（CPU、DDR、fio 参数、样本 sha）相同的两次结果才能互相比较，
  见[结果差异与合理对比](#结果差异与合理对比)。

### 结果目录

```
results/<时间>/
├── summary.txt        终端汇总
├── info               测试条件（算法、基准、CPU / DDR 频率、fio、样本）
├── run.log            详细日志：锁频、样本导出、每个算法的写入 / pending / mm_stat / fio / DDR
├── compression.csv    algo, 压缩比, 物理压缩比, 写入速度, orig/compr/mem_used 字节, sddc aliases/deltas
├── read-speed.csv     algo, 块大小, MiB/s, IOPS, mean/p50/p90/p99/p99.9 延迟 (ns)
├── dataset.meta       所用样本的 meta
└── <algo>/            mm_stat, sddc_stat, compratio, physical-ratio, write-mib-s,
                       ddr-khz（fio 期间 DDR 采样）, pc-<档位>.json（fio 原始输出）
```

## 结果差异与合理对比

**不同人、不同设备测出的结果可能差别很大，这是正常的。** 主要原因：

| 因素 | 影响 |
| --- | --- |
| 处理器型号 | CPU 微架构、缓存大小、内存控制器不同，解压速度和读吞吐差别很大 |
| 系统版本 | Android 版本、内核版本和配置、zram / zsmalloc 实现、厂商调度和调频策略都不同 |
| 处理器体质 | 同型号芯片的体质（bin）有差异，同频下的功耗、发热和降频表现不同 |
| 可用频点 | 各平台的 CPU / DDR 档位不同，锁定频率是取最接近的档位，未必与本文示例相同 |
| 样本内容 | 每个人的样本来自自己 zram0 里的应用数据，内容不同，压缩比和解压速度也不同 |
| 温度与后台 | 机身温度、温控降频、后台任务、屏幕刷新都会影响结果 |
| 测试本身的波动 | 同一台设备连续测几次，读吞吐也会有几个百分点的波动，写入速度波动更大 |

请合理对比：

- **在同一次运行内比较算法**，看汇总里相对基准的百分比，而不是拿绝对数值跨设备比。
- 跨次比较时，确认“测试条件”一致：同一设备、同一样本（sha 相同）、相同的 CPU / DDR 频率和 fio 参数。
- 差距只有几个百分点时，多跑几次（建议 3 次以上）看是否稳定，不要根据单次结果下结论。
- 测试前让设备冷却、插电、关掉无关应用，测试过程中不要操作手机。
- 分享或引用结果时，同时附上 `summary.txt` 里的测试条件（处理器、内核、CPU / DDR 频率、样本大小）。
- 本仓库中的示例数据只说明输出格式，不代表其他设备上的表现。

## 目录结构

```
.
├── run-zram-bench.sh    主机侧：推送 → 设备上跑测 → 拉回结果
├── zram-bench.sh        设备侧：准备样本 + 跑测 + 汇总（需 root）
├── bin/
│   ├── fio              fio 3.38，arm64 Android（NDK r26c 编译）
│   └── mkcorpus         arm64 静态二进制，从 zram0 导出样本
├── src/mkcorpus.c       mkcorpus 源码
├── samples/             样本（不进 git）
└── results/             测试结果（不进 git）
```

## 编译二进制

mkcorpus：

```sh
aarch64-linux-gnu-gcc -O2 -static -Wall -Wextra -o bin/mkcorpus src/mkcorpus.c
```

fio 使用上游 [fio](https://github.com/axboe/fio) 的 `fio-3.38` 版本，用 Android NDK 编译为 arm64。
也可以换成自己编译的 fio：放到 `bin/fio`，或在设备上用 `FIO=/path/to/fio` 指定。

## 注意事项

- 测试期间会修改 CPU 频率和 governor、DDR 投票和 bwmon 限制，并 hot-add 一个 zram 设备；脚本退出时会恢复。
- 在主机上按 Ctrl-C：主机脚本会通知设备上的测试立即停止，并等它恢复完设备状态（通常 1～2 秒）再退出。
  adb 会话断开时，设备上的测试通常也会收到信号并自行进入清理。
- 如果脚本被 `kill -9`、断电等方式强制结束来不及恢复，运行 `adb shell su -c 'sh /data/local/tmp/zram-bench-package/zram-bench.sh restore'`
  手动恢复；下次运行测试时也会先自动恢复。测试进行中的状态记录在设备上的 `.bench-state` 文件里。
- 测试会占用约等于样本压缩后大小的内存，内存紧张的设备可调小 `SAMPLE_MB`。
- 测试时尽量不要操作手机，前台应用和屏幕刷新会给 CPU 和 DDR 带来额外负载。

## 许可证

本仓库以 [GPL-2.0](LICENSE) 许可发布。

## 第三方组件

`bin/fio` 是 [fio](https://github.com/axboe/fio) 的编译产物，fio 以 GPL-2.0 许可发布，源码见其仓库 `fio-3.38` 标签。
