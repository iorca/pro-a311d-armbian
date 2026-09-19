# PRO-A311D (Amlogic A311D) Armbian 适配说明

> 家族: `meson-g12b` (与 Khadas VIM3 同 SoC / A311D)
> 参考板: Khadas VIM3 (`khadas-vim3.conf`)
> 核心板: PRO-A311D, 基于 Amlogic **W400** 参考设计 (`amlogic-dt-id = "g12b_w400_b"`)
> 内核: 主线 mainline **6.18.52** (`current` 分支; `KERNELPATCHDIR=archive/meson64-6.18`)
> FIP: 厂商 SDK 的 bl2/bl30/bl31 (不走复用 khadas-vim3 FIP 树的路线)
> 构建框架: armbian/build **26.11.0-trunk** (新版 CLI)
>
> **状态 (2026-09-19)**: ① u-boot ② 内核 ③ 完整镜像 **三步全部实跑通过**,
> 且已 loop 挂载确认镜像内 `/boot/dtb/amlogic/meson-g12b-a311d-pro-a311d.dtb` 存在。
> 详见第七节。**仅剩真机验证**(PHY/HDMI/BT/DVFS 极性), 不影响编译。

> ### 修订记录
>
> **rev2 (本仓库化改造)** —— u-boot 的 FIP 注入方式改了, 其余结论不变:
>
> | | rev1 (本机 VM) | rev2 (本仓库 / CI) |
> |---|---|---|
> | FIP 入口 | 在**上游** `config/sources/families/meson-g12b.conf` 里现场插入 `elif [[ $BOARD == pro-a311d ]]` 分支 | 本仓库 `userpatches/config/sources/families/meson-g12b.conf` **整体重定义** `uboot_custom_postprocess()`; 上游文件一个字节不动 |
> | 板级 conf | `config/boards/pro-a311d.conf` | `userpatches/config/boards/pro-a311d.conf` |
> | FIP 树路径 | 硬编码 `/home/orca/PRO-A311D/...` | `${FIP_TREE_PRO_A311D:-${SRC}/fip/pro-a311d}`, 随仓库走 |
> | dts 落点 | `userpatches/kernel/archive/meson64-6.18/dt/` | **不变** (目录名改为从上游 `case $BRANCH` 派生) |
>
> 改的理由: 整文件覆盖上游 family conf 会随上游重构**静默漂移** —— 26.x 已经把
> `khadas-vim3` / `odroidn2*` / `cainiao-cniot-core` 改走板级
> `post_uboot_custom_postprocess` hook, family 里只留 `:`。覆盖 = 冻结在旧结构。
> 而 `source_family_config_and_arch()` 的 family 路径是
> `("${SRC}/..." "${USERPATCHES_PATH}/...")` **两个都 source、同 shell、后者生效**,
> 所以覆盖式注入有官方支持, 不需要动上游。
> 第二节 2.2 / 第三节已按 rev2 更新。

---

## 一、适配结论 (确定性部分)

1. **`exit 2` 已修复**。`meson-g12b.conf` 的 `uboot_custom_postprocess()` 原本是
   if/elif 链，只认 `odroidn2*/khadas-vim3/radxa-zero2/bananapim2s`，其余 `exit 2`。
   已在链中新增 `elif [[ $BOARD == pro-a311d ]]` 分支，指向
   `$SRC/cache/sources/amlogic-boot-fip/pro-a311d`。

2. **FIP 树已组装** (VM 上 `/home/orca/PRO-A311D/amlogic-boot-fip/pro-a311d/`)。
   以 LibreELEC/amlogic-boot-fip 的 `khadas-vim3` 树为基底，覆盖厂商 g12b 专有二进制:
   `bl2.bin` / `bl30.bin` / `bl31.img` / `aml_encrypt_g12b` / 全套 `*.fw`。
   辅助文件 `blx_fix.sh/acs.bin/bl301.bin` 取自 vim3 树; `zero_tmp/bl*_zero.bin/bl21.bin`
   由 `blx_fix.sh` 运行时生成, 不需预置。校验通过。

3. **板级配置 `pro-a311d.conf`** 已写, 基于 `khadas-vim3.conf`。

4. **主线化 dts `meson-g12b-a311d-pro-a311d.dts`** 已写并**通过实编验证**:
   - 去除了全部 vendor 专用节点 (`rp_power` / `rp_gpio` / `stm706` / vendor audio /
     `&partitions` / camera `&sensor` `&iq` / LCD dtsi / `amlogic-dt-id`)。
   - 内部 PHY: `internal_phy=<1>` (vendor) → 主线 `phy-handle = <&internal_ephy>` + `phy-mode = "rmii"`
     (`internal_ephy` 在 `meson-g12-common.dtsi:1727`, `ethernet-phy@8`, max-speed 100)。
   - 串口: `uart_AO`(调试) / `uart_A`(BT) / `uart_C`(RS485) / `uart_AO_B`(uart1) 均 enable。
   - RTC: HYM8563 @0x51 on `i2c_AO` (`compatible = "haoyu,hym8563"`)。
   - 存储: eMMC (`sd_emmc_c`) + SD (`sd_emmc_b`) enable, 否则找不到 rootfs。
     pinctrl 用 6.1 主线真实 label: eMMC = `emmc_ctrl_pins`+`emmc_data_8b_pins`+`emmc_ds_pins`+`emmc_clk_gate_pins`;
     SD = `sdcard_c_pins`+`sdcard_clk_gate_c_pins` (旧的合并名 `emmc_pins`/`sdcard_pins` 在 6.1 已不存在)。
   - run_led = `gpio-leds` (GPIOAO_10)。
   - **按用户最新 6 条指令追加的改造** (均已落盘并重新实编):
     1. **删除全部 GPIO 控制供电稳压器**: USB(`GPIOA_1`)/HUB 复位(`GPIOA_3`)/风扇(`GPIOZ_11`)/OTG VBUS(`GPIOZ_9`) 四个 `fixed-regulator` 节点整段移除 —— 这些口硬件常开, 不做 DT 开关 (指令 1)。
     2. **SD 卡检测**: `broken-cd` 轮询 → `cd-gpios = <&gpio GPIOC_6 GPIO_ACTIVE_LOW>`; 并加启动不拉低 CARD_DET 的告警注释 (指令 2)。
     3. **BT 芯片 AP6256**: `uart_A` 下补 `bluetooth { compatible = "brcm,bcm4345c5"; }`, 三脚按 SDK 接法: `shutdown-gpios = GPIOA_6`(复位) / `device-wakeup-gpios = GPIOA_5`(host 唤醒模块) / `host-wakeup-gpios = GPIOX_19`(模块唤醒 host), 全部 `GPIO_ACTIVE_HIGH` (指令 3)。
     4. **OTG VBUS / host-device 选择脚去除**: 删除 `vbus_otg` 节点及 `&usb` 里的 `vbus-supply` 注释; `&dwc3` 固定 `dr_mode = "host"` (指令 4)。
     5. **CPU 动态调压 (DVFS) 已恢复** (指令 5 落地的修正版): 板级补两个 `pwm-regulator` 并接 `cpu-supply`,
        `vddcpu`(cluster0 A53) 走 PWM AO CD ch1/GPIOAO_E, `vddcpu_a`(cluster1 A73) 走 PWM AB ch0/GPIOA_E,
        电压表取自 vendor W400 BSP (680k–1040k, 反相), OPP 表 (731k–1011k) 已覆盖。
        原始 vendor BSP (`mesong12b.dtsi` 的 `vddcpu0`/`vddcpu1`) 即此接法; 主线 g12b 全链 (含 VIM3/odroid-n2)
        **默认不接 `cpu-supply`**, 故上一版"占位软稳压器"等于静默关掉 DVFS, 已纠正。
     6. **打开 HDMI**: 新增 `&hdmi_tx { status = "okay"; pinctrl-0 = <&hdmitx_hpd_pins>; pinctrl-names = "default"; }` (指令 6)。
   - **验证**: VM 上用 `linux-6.1.y` 主线 dtsi 链 (meson-g12b-a311d.dtsi → meson-g12b.dtsi →
     meson-g12.dtsi → meson-g12-common.dtsi) + `dt-bindings/gpio/meson-g12a-gpio.h`, 经 `cpp` 预处理后
     `dtc` 实编通过, 生成 `pro-a311d.dtb` (47780 B, 较上一版 46777 B 大是因为新增了 2 个 pwm-regulator + 电压表)。仅余主线 dtsi 自带的
     `unit_address_vs_reg` / `simple_bus_reg` warning (所有 g12b 板共有, 非本 dts 引入)。
     dtb 反解确认: `cd-gpios=<0x1b 0x2f 0x01>`(=GPIOC_6, ACTIVE_LOW)、`hdmi_tx` status=okay + hpd pinctrl、
     `bluetooth` compatible=brcm,bcm4345c5、无 `vbus-supply`、无 `broken-cd`;
     **DVFS 落盘**: 2 个 `pwm-regulator`(VDDCPU/VDDCPU_A) 各带 38 项 `voltage-table`(1040000@duty0 → 680000@duty100, 反相正确),
     6 个 CPU 节点 (`cpu0/cpu1`→vddcpu, `cpu100`–`cpu103`→vddcpu_a) 均接 `cpu-supply`。
     落点方式为 armbian 26.x 原生 `userpatches/.../dt/` 机制 (**不是** patch 文件),
     详见第二节 2.1; 已在真实内核编译中验证 dts 进源码树 + Makefile 自动加行 + dtc 出 dtb。

5. **u-boot 烧写方式无需改**。`write_uboot_platform()` (meson64_common.inc:243)
   对所有 g12b 板相同 (前 442 字节 + 从扇区 1 续写)。

---

## 二、文件清单 (本仓库 → armbian/build 的落点)

**本仓库全部内容都落在 `userpatches/` 与 `fip/` 下, 上游文件零改动。**

```
本仓库                           →  armbian/build/                        机制依据
──────────────────────────────────────────────────────────────────────────────────────────
userpatches/config/boards/
  pro-a311d.conf                 →  userpatches/config/boards/             config-prepare.sh:100
                                                                            config_source_board_file()
                                                                            board_file_paths 含 userpatches
userpatches/config/sources/
  families/meson-g12b.conf       →  userpatches/config/sources/families/   main-config.sh:582
                                                                            source_family_config_and_arch()
                                                                            两个路径都 source, 后者覆盖
dts/
  meson-g12b-a311d-pro-a311d.dts →  userpatches/kernel/<KERNELPATCHDIR>/dt/  dt_makefile_patcher.py
                                                                            (目录名由脚本派生, 见 2.1)
fip/pro-a311d/  (19 文件 2.79 MB)→  fip/pro-a311d/                          cache/ 之外, 原因见第三节
```

落点由 `scripts/deploy-to-build.sh` 幂等完成 (自动推导补丁目录 + 清理历史错误落点 + 自检)。
CI 与本地共用这一份脚本 (`.github/workflows/build.yml` 调它), 不重写第二遍逻辑。

### 2.1 dts 落点: 必须走 `userpatches/.../dt/` 原生机制

> ⚠️ **不要把 dts 做成 `patch/kernel/meson64-current/add-pro-a311d-dts.patch`。** 这条路是死的。

**为什么死**: armbian 26.x 的 `KERNELPATCHDIR` 默认值是 `archive/meson64-6.18`
(由 BRANCH 决定, 见 `config/sources/families/include/meson64_common.inc` 的 `case $BRANCH` 块:
`oldlts→6.12 / current→6.18 / edge→7.2 / bleedingedge→7.3`), **不是** `meson64-current`。
放错目录的两个后果:
1. 补丁根本不会被读 → dts 不进内核源码树 → 镜像里没有本板 dtb;
2. 更隐蔽的是 —— **内核补丁哈希不变** → 命中 armbian 官方 ORAS 远程缓存
   (`ghcr.io/armbian/os/kernel-meson64-current:...`) → 直接下载预编内核, 日志里
   只有一行 `Obtaining artifact from remote cache`, 本地连编都不编。

**实测证据 (2026-09-19 首次全镜像)**: 镜像 `Armbian-unofficial_..._Pro-a311d_bookworm_current_6.18.52.img`
(2.4G) 产出成功, 但挂载后 `/boot/dtb/amlogic/` **没有** `meson-g12b-a311d-pro-a311d.dtb`
(`dpkg-deb -c linux-dtb-current-meson64*.deb | grep -c pro-a311d` = **0**),
而 `armbianEnv.txt` 里 `fdtfile=amlogic/meson-g12b-a311d-pro-a311d.dtb` 照写 → **上板必起不来**。

**正解 (已实装并验证)**: 用 26.x 原生 dt 机制, 把**裸 `.dts`** 放进
```
userpatches/kernel/archive/meson64-6.18/dt/meson-g12b-a311d-pro-a311d.dts
```
依据 `patch/kernel/archive/meson64-6.18/0000.patching_config.yaml`:
```yaml
  dts-directories:
    - { source: "dt", target: "arch/arm64/boot/dts/amlogic" }
  auto-patch-dt-makefile:
    - { directory: "arch/arm64/boot/dts/amlogic", config-var: "CONFIG_ARCH_MESON" }
```
`lib/tools/common/dt_makefile_patcher.py:copy_bare_files()` 遍历 core + user 两类 root dir
(`patching.py`: `CONST_PATCH_ROOT_DIRS` 同时收 `$SRC/patch/kernel/<dir>` 和
`$USERPATCHES_PATH/kernel/<dir>`; `root_types_order = ['core','user']`, 同名时 userpatches 胜出),
把 `dt/*.dts` 拷进源码树, 并自动改 Makefile —— **不需要手改 Makefile, 也不需要做 patch 文件**。

**连带效果 (关键)**: `artifact-kernel.sh:104-107` 把 userpatches 目录内容也算进内核补丁哈希
```bash
for patch_dir in ${KERNELPATCHDIR}; do
    kernel_patch_dirs+=("${SRC}/patch/kernel/${patch_dir}" "${USERPATCHES_PATH}/kernel/${patch_dir}")
done
calculate_hash_for_all_files_in_dirs "${kernel_patch_dirs[@]}"
```
→ 哈希变 → 本地 + 远程缓存双 miss → **必然本地编内核**。

**实测验证 (2026-09-19 `./compile.sh kernel BOARD=pro-a311d BRANCH=current`)**:
```
User patches directory for kernel [ .../userpatches/kernel/archive/meson64-6.18 ]
Compiling current kernel [ 6.18.52 ]            ← 本地编, 非远程缓存
make -j12 -C .../linux-kernel-worktree/6.18__meson64__arm64 all Image
```
源码树内确认三件事全部生效:
- `arch/arm64/boot/dts/amlogic/meson-g12b-a311d-pro-a311d.dts` 存在, md5 `278a626ada72e41d75941827bc7241d4`
- `Makefile:150  dtb-$(CONFIG_ARCH_MESON) += meson-g12b-a311d-pro-a311d.dtb` (autopatcher 自动加的)
- 编译日志出现 `DTC  arch/arm64/boot/dts/amlogic/meson-g12b-a311d-pro-a311d.dtb`

唯一注意点: 补丁目录名随内核大版本变 (`meson64-6.18` → 将来 6.19 就要跟着改)。
`scripts/deploy-to-build.sh` 从 `meson64_common.inc` 的 `case $BRANCH` 块 awk 解析
`KERNEL_MAJOR_MINOR`, 再拼成 `archive/meson64-<MAJOR.MINOR>`, **不写死版本号**;
并断言上游 `patch/kernel/<该目录>/0000.patching_config.yaml` 确实存在 ——
不存在就**报错退出**, 而不是静默落一个不生效的位置。

---

## 三、FIP 树处理 (关键集成步骤)

> ⚠️ **FIP 树必须放在 `cache/` 之外。** 构建时
> `fetch_sources_tools__libreelec_amlogic_fip()` (meson64_common.inc:24) 会
> `fetch_from_repo "https://github.com/LibreELEC/amlogic-boot-fip" "amlogic-boot-fip" branch:master`,
> 把 `$SRC/cache/sources/amlogic-boot-fip` **reset/clean 成纯上游仓库**。LibreELEC 仓库里
> **没有** `pro-a311d` 目录, 所以任何拷进 `cache/sources/amlogic-boot-fip/` 的自定义树
> **每次构建都会被 fetch 阶段的 git clean 清掉**。
> 实测 (2026-09-18 首次编译): 树拷进 cache 后 `uboot_g12_postprocess` 报
> `.../pro-a311d/blx_fix.sh: No such file or directory` (Error 127), 整个 pro-a311d 目录被删。

**rev2 正解 (本仓库采用, 上游文件零改动)**: 不在上游文件里插分支, 而是用
**userpatches family 覆盖层**整体重定义 `uboot_custom_postprocess()`。

源码依据 —— `lib/functions/configuration/main-config.sh` 的
`source_family_config_and_arch()`:
```bash
declare -a family_source_paths=("${SRC}/config/sources/families/${LINUXFAMILY}.conf"
                                "${USERPATCHES_PATH}/config/sources/families/${LINUXFAMILY}.conf")
for family_source_path in "${family_source_paths[@]}"; do
    [[ ! -f "${family_source_path}" ]] && continue
    source "${family_source_path}"          # ← 两个都 source, 同一个 shell
    family_sourced_ok=$((family_sourced_ok + 1))
done
```
core 先 source, 本仓库的后 source → 同 shell 内函数重定义, **后定义的生效**。

`userpatches/config/sources/families/meson-g12b.conf`:
```bash
if [[ "${BOARD}" == "pro-a311d" ]]; then
	function uboot_custom_postprocess() {
		local fip_tree="${FIP_TREE_PRO_A311D:-${SRC}/fip/pro-a311d}"
		uboot_g12_postprocess "${fip_tree}" g12b
	}
fi
```
`userpatches/config/boards/pro-a311d.conf`:
```bash
FIP_TREE_PRO_A311D="${FIP_TREE_PRO_A311D:-${SRC}/fip/pro-a311d}"
```
用 `${VAR:-default}` 而不是硬编码路径, 所以: 仓库自带一份就够, 换机器不用改代码;
本地开发想指自己的目录就 `export FIP_TREE_PRO_A311D=/your/path/pro-a311d`。

为什么不整文件覆盖上游 `config/sources/families/meson-g12b.conf`:
上游 26.x 已经重构过这个文件 (khadas-vim3 / odroidn2* / cainiao-cniot-core 改走板级
`post_uboot_custom_postprocess` hook, family 里只留 `:`), **覆盖 = 冻结在旧结构**,
以后上游一动就静默丢改动。覆盖层只改一个函数, 不承担这个风险。

**rev1 记录 (曾在 VM 上用过, 已废弃)**: 在上游文件里现场插入
`elif [[ $BOARD == pro-a311d ]]; then uboot_g12_postprocess "${FIP_TREE_PRO_A311D:-...}" g12b`。
功能等价, 但污染上游工作树。

**另一条路 (上游化)**: fork `LibreELEC/amlogic-boot-fip`, 加 `pro-a311d/` 目录推上去,
即可从上游仓库正常 fetch。注意上游 meson64_common.inc 里已有
`@TODO: these should come from FIP_TREE_BOARD/FIP_TREE_FAMILY vars in board.conf` ——
未来上游可能原生支持该变量。

**`lpddr3_1d.fw` 不是坑**: `uboot_g12_postprocess` 是把 ddr4/ddr3/lpddr4/lpddr3 **全部 ddrfw
一起打包**进 `--bootmk`(有该文件则多 `--ddrfw9`), BL2 启动时按硬件自动探测选固件。VIM3(LPDDR4)
同样带该文件, 照跑。

**编译验证结果 (2026-09-18)**: `./compile.sh uboot BOARD=pro-a311d BRANCH=current` 实跑通过,
产出 `linux-u-boot-pro-a311d-current_...2022.07-Se092-Pc5a6-H23f7-Va2df-B6a81-R448a_arm64.deb`
(2.1 MB), 内含 `u-boot.bin` **1,184,112 B** —— 合法 Amlogic FIP(加密 bl2 签名头 +
`@AML`/`AMLIFPG` magic + bl30/bl31/bl33 + 9 个 ddrfw)。Runtime 0:53 min。

打包/落点/验收脚本见 `scripts/` (rev2: `deploy-to-build.sh` 幂等落点 + `build.sh` 启动器 +
`verify-output.sh` 产物验收)。

---

## 四、dts 待核对项 (需对照底板原理图, 未确认前不要当作结论)

这些项 dts 里已留注释/占位, 但极性/接法需原理图定论, 否则可能不工作或误动作:

| 项 | dts 当前写法 | 状态 / 待核对 |
|----|----|----|
| USB 供电 `GPIOA_1` | **已删除** 供电节点 | 指令 1: 硬件常开, 不要 DT 开关 |
| USB HUB 复位 `GPIOA_3` | **已删除** 供电节点 | 指令 1: 同上 |
| 风扇 `GPIOZ_11` | **已删除** 供电节点 | 指令 1: 同上 |
| OTG VBUS `GPIOZ_9` | **已删除** `vbus_otg` 节点及 `&usb` 的 `vbus-supply` | 指令 4: 去除 OTG 供电控制 |
| OTG host/device 选择 | 未建模 (`&dwc3` 固定 `dr_mode = "host"`) | 当前按纯 host 用; 若以后要 device 模式需补 mux 脚 (待核对) |
| SD 卡检测 | `cd-gpios = <&gpio GPIOC_6 GPIO_ACTIVE_LOW>` | **已改** (指令 2); 仍待核对: 启动阶段 GPIOC 不拉低避免 romcode 误从 SD 启动 |
| BT 模块 AP6256 | `bluetooth { compatible = "brcm,bcm4345c5"; }` | **已填** (指令 3); 待核对三脚极性 (默认高有效) |
| `uart_AO_B` 引脚组 | `uart_ao_b_2_3_pins` | 若底板用 8/9 脚改 `uart_ao_b_8_9_pins` (待核对) |
| CPU/核心电压 `vddcpu*` (DVFS) | 2×`pwm-regulator`: vddcpu(PWM AO CD ch1/GPIOAO_E)→cluster0, vddcpu_a(PWM AB ch0/GPIOA_E)→cluster1 | **已恢复动态调压** (修正指令 5); 待核对见下方 DVFS 专列 |
| 大核电压 PWM 路由 | `vddcpu_a` 走 `pwm_ab` ch0 / GPIOA_E (同 vendor `vddcpu1`) | 待核对: 若 PRO-A311D 大核实际走 PWM AO CD ch0 (同 VIM3 参考板), 改 `pwms=<&pwm_AO_cd 0 1500 0>` 并换 AO_CD ch0 的 pin |
| PWM 输出脚 (GPIOAO_E / GPIOA_E) | pinctrl `pwm_ao_d_e_pins` / `pwm_a_e_pins` (主线 label) | 待核对: 是否为核心板真实 PWM 输出脚 (vendor `pwm_ao_d_pins3`/`pwm_a_e2` 在 6.1 不存在, 已映射) |
| `voltage-table` 极性 | 反相 (占空比越大电压越低), 取自 vendor W400 BSP | 待核对: 与核心板真实电压表一致; 极性反了会导致高压低配 |
| 音频 | 未适配 (删除 vendor audio 块) | 需 codec 接线才能加 `amlogic,g12a-sound-card` |
| 显示 HDMI | `&hdmi_tx` enable + `hdmitx_hpd_pins` | **已打开** (指令 6); 待核对: HDMI 5V 是否确实常开 (否则补 `hdmi-supply`) |

> **`vbus-supply` 是什么** (用户问): 它是 USB 控制器节点 (`&usb`, 即 `usb@ff400000` 的
> meson 复合控制器) 上的一个属性, 指向一个 `regulator`, 含义是"这个 USB 口对外供电的 VBUS
> 由哪个稳压器提供"。在 **host 模式**下, 内核要用它给插在口上的外设供 5V; 在 OTG device 模式下
> 不需要 (由对端供 VBUS)。本板 OTG 口去掉供电控制 (指令 4), 故节点和 `vbus-supply` 引用一并删除,
> `&dwc3` 固定 `dr_mode = "host"` 即可 (host 模式下不依赖该 regulator 给外设供电, 由硬件常开 5V 提供)。

> **DVFS 结论 (回答用户"原始 dts 有没有动态调压 / VIM3 带不带")**:
> - **原始 vendor PRO-A311D dts 带动态调压**: `mesong12b.dtsi` 的 `vddcpu0`(PWM AO CD ch1) / `vddcpu1`(PWM AB ch0)
>   是 `pwm-regulator`, vendor W400 基 dts 有完整 OPP 表 (opp-microvolt 770k–1040k)。上一版把 `vddcpu*` 写成
>   `regulator-fixed` 占位, 等于把 DVFS 电压随频调节**关掉** (且无任何节点引用它, 是死节点)。
> - **主线 VIM3 (6.1/6.6/6.12) 不带调压**: 主线 g12b 公共链 (VIM3 / odroid-n2) **不接 `cpu-supply` / 无 `pwm-regulator`**,
>   即只做频率调速, 电压靠 u-boot 固定。所以"参考 VIM3"在调压上**不能**提供带调压的范例。
> - **本版已恢复**: 按 vendor 路由补回两个 `pwm-regulator` 并接 `cpu-supply`, 走主线可编译的 pinctrl label,
>   OPP 电压范围全部落在 680k–1040k 表内。代价: 大核 PWM 通道路由 (PWM AB vs PWM AO CD ch0) 与电压表极性待原理图定论
>   (见第四节 DVFS 专列), 否则可能高压低配或脚位错。

---

## 五、构建命令

### 5.1 用本仓库的脚本 (推荐, CI 与本地同一套)

```bash
bash scripts/deploy-to-build.sh ~/armbian-build      # ① 落 overlay (幂等, 带自检)
bash scripts/build.sh kernel-dtb ~/armbian-build     # ② 只编设备树, 几分钟, 先验落点
bash scripts/build.sh build ~/armbian-build          # ③ 全量镜像
bash scripts/verify-output.sh ~/armbian-build        # ④ 验收 (编完必跑, 别靠肉眼)
```

CI: Actions 页面 → `build` → Run workflow (见 `.github/workflows/build.yml`)。

### 5.2 手工命令

```bash
cd ~/armbian-build
# 26.x 新版 CLI: artifact 是位置参数, 不是 api=xxx
./compile.sh uboot      BOARD=pro-a311d BRANCH=current                    # FIP 链路, Runtime 0:53
./compile.sh kernel-dtb BOARD=pro-a311d BRANCH=current                    # 只出 dtb, 验落点
./compile.sh kernel     BOARD=pro-a311d BRANCH=current                    # 出内核 deb
./compile.sh build      BOARD=pro-a311d BRANCH=current RELEASE=bookworm   # 全量镜像
```

### 5.3 root / 非终端 —— rev1 那条"必须禁止 root"是错的, 已修正

源码依据 `lib/functions/cli/utils-cli.sh` 的 `cli_standard_relaunch_docker_or_sudo()`:
```bash
if [[ "${EUID}" == "0" ]]; then
    if [[ "${ARMBIAN_RELAUNCHED}" != "yes" && "${ALLOW_ROOT}" != "yes" ]]; then
        display_alert "PROBLEM: don't run ./compile.sh as root or with sudo" ... "err"
        if [[ -t 0 ]]; then # 非交互构建是可以以 root 跑的…
            exit_if_countdown_not_aborted 10 "directly called as root"
        fi
    fi
    display_alert "Already running as root" "great, running normally" "debug"
else # 非 root
    ...
```

| 场景 | 行为 |
|---|---|
| 终端里以 root/sudo 跑 | stdin 是 tty → 走 10 秒倒计时 → **退出** |
| 终端里以普通用户跑 | 走 else → `sudo --preserve-env` 自己重新拉起 (需 sudo 免密) |
| **CI / `</dev/null` / setsid 后台 + root** | stdin 非 tty → 倒计时分支不执行 → **只打印 err 后照跑** |
| CI + 非 root | 走 else → 检测到 runner 有 Docker → **转进 Docker 容器编译** |

所以:
- **本地终端**: 普通用户, 不要 sudo (`scripts/build.sh` 已强制检查 uid!=0)
- **CI**: 直接 `sudo -E ./compile.sh`, 再给 `ALLOW_ROOT=yes` 把告警也消掉 (少一层 Docker 黑盒)

### 5.4 非交互门控必须走 env, 不能放命令行

`KERNEL_CONFIGURE` / `UBOOT_CONFIGURE` 放命令行会被 CLI 白名单**静默丢弃**
(判据: 日志 `Repeat Build Options` 行里看不到它们就是被丢了)。必须 export:
```bash
export EXPERT=yes KERNEL_CONFIGURE=no UBOOT_CONFIGURE=no BUILD_DESKTOP=no BUILD_MINIMAL=no
```
- `BUILD_DESKTOP=no` 之后**仍要**给 `BUILD_MINIMAL` 赋非空值, 否则 `ask_standard_or_minimal` 照弹
- 交互点清单见 `lib/functions/configuration/interactive.sh`
- `userpatches/config-default.conf` **不是机制** —— `cli/entrypoint.sh:64` 只有一句 `@TODO` 注释

### 5.5 为什么先跑 `kernel-dtb` / `kernel`, 不直接 `build`

因为 dts 落点错会导致「镜像编得出来但里面没有本板 dtb」, 而日志里**一条报错都没有**
(走了 ORAS 远程缓存), 上板才发现起不来 —— 实测白等 3 小时。
`kernel-dtb` 几分钟, `kernel` 之后 `dpkg-deb -c <deb> | grep -c pro-a311d` 一数就知道。
通过后再 `build`, 内核命中本地缓存, 镜像阶段很快 (实测 8:59)。
`scripts/verify-output.sh` 把这一串判据固化成脚本。

注: `api=uboot` 这种旧写法在 26.x 已废弃 (artifact 改位置参数)。

---

## 六、已知风险

1. `BOOTCONFIG` 暂用 `khadas-vim3_defconfig` (同 SoC)。u-boot 自身会用 VIM3 的 dts,
   对 PRO-A311D 仅带来读不到板级差异的风险, 不影响 SoC 级启动。要干净可派生
   `pro-a311d_defconfig` (待核对)。
2. dts **已用 `linux-6.1.y` 主线 dtsi 链实编通过** (见第一节第 4 点), 最新 6 条指令改完
   后已重新 `cpp+dtc` 实编 + `git apply --check` 通过。**u-boot 编译链路已实跑通过**
   (`./compile.sh uboot` 产出 u-boot deb, 见第三节末)。真机启动、内部 PHY link-up、HDMI 显示、
   BT 加载 **仍待实板验证** (见第四节待核对项)。
3. g12b 内部 PHY (RMII) 主线支持需实测 link-up; 若不通, 检查 `phy-mode` 与
   `eth_phy` mdio-mux 切换 (int_mdio vs ext_mdio)。
4. HDMI / BT 是新加节点, 仅通过编译与 dtb 反解确认结构正确, **未上真机**。HDMI 热插拔
   不识别优先查 HPD 脚电平; BT 起不来优先查三脚极性 (shutdown/device-wakeup/host-wakeup)。
5. ~~完整镜像尚未编~~ → **已完成, 见第七节**。`./compile.sh build` 首编(2026-09-19 01:22)
   产出镜像但缺本板 dtb (dts 落点错, 见第二节 2.1); 修正落点后 `./compile.sh kernel` 本地编内核
   (51:15) + `./compile.sh build` (8:59, 内核命中本地缓存) 产出**含 dtb 的正确镜像**。

---

## 七、构建结果 (2026-09-19, 全部实跑验证)

| 步骤 | 命令 | Runtime | 产物 |
|---|---|---|---|
| ① u-boot | `./compile.sh uboot BOARD=pro-a311d BRANCH=current` | 0:53 | `linux-u-boot-pro-a311d-current_...2022.07-....deb` 2.1 MB (内含合法 Amlogic FIP 1,184,112 B) |
| ② 内核 | `./compile.sh kernel BOARD=pro-a311d BRANCH=current` | 51:15 | linux-image 310 MB / linux-dtb **6.9 MB** / linux-headers 108 MB / linux-libc-dev 7.9 MB |
| ③ 镜像 | `./compile.sh build BOARD=pro-a311d BRANCH=current RELEASE=bookworm` | 8:59 | `..._Pro-a311d_bookworm_current_6.18.52.img` **2,487,222,272 B** |

内核版本串 (补丁哈希 `P` 段即此时刻的 userpatches+core 补丁集合哈希):
```
6.18.52-S8f37-Df596-P7944-C2bdc-Hf4c5-HK01ba-Ve377-Bc768-R448a
                 ↑↑↑↑
  修正落点前是 P8717 (dts 没进源码树, 走 ORAS 远程缓存)
  修正落点后是 P7944 (本地编, 含 pro-a311d)
```
→ `P` 段变化就是"这次真的本地编了"的判据。

**镜像内容实测 (loop 挂载, `losetup -Pf` → mount `/dev/loop0p1`)**:
```
/boot/dtb/amlogic/meson-g12b-a311d-pro-a311d.dtb                       77055 B  ✅
/boot/dtb-6.18.52-current-meson64/amlogic/meson-g12b-a311d-pro-a311d.dtb  77055 B  ✅
/usr/lib/linux-image-6.18.52-current-meson64/amlogic/...dtb               77055 B  ✅
armbianEnv.txt: fdtfile=amlogic/meson-g12b-a311d-pro-a311d.dtb   ← 本次能对应上了
/boot/vmlinuz-6.18.52-current-meson64                                   42404352 B
/boot/uInitrd-6.18.52-current-meson64                                   28168094 B
```
(注: dtb 77055 B 比本地手工 `cpp+dtc` 的 47780 B 大, 因为内核 Makefile 用 `-@` 保留
 `__symbols__`/`__fixups__` overlay 符号 —— 属正常, 不是内容差异。)

**dtb 反解复核** (从镜像里的 dtb 抽证): `cd-gpios = <0x20 0x2f 0x01>` (pin 47 = GPIOC_6, ACTIVE_LOW)、
`compatible = "brcm,bcm4345c5"`、`regulator-vddcpu` / `regulator-vddcpu-a` 两个 `pwm-regulator`、
`cpu0/cpu1 → cpu-supply=<0x3a>`、`cpu100–cpu103 → cpu-supply=<0x3c>`。

**镜像 SHA256** (`build-evidence/...img.sha`):
```
87db74ae20861ee258b1acef6781251a51f238e5275ccea62cda90e5a3fdfb21
```

**证据文件**: `build-evidence/` 下 — 镜像构建报告 `.img.txt`、SHA256 `.img.sha`、
以及 `build-kernel.log` / `build-image.log` 两份完整 armbian 构建日志。

**仍待实板验证** (与编译无关, 见第四节): 内部 PHY link-up、HDMI 显示、BT 加载、
DVFS 大核 PWM 路由与电压表极性、SD 卡 CARD_DET 启动电平。
