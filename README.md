# PRO-A311D — Armbian 适配 (Amlogic A311D / W400)

把 **PRO-A311D** 核心板接进 [armbian/build](https://github.com/armbian/build)，云端或本地出可烧录镜像。

- SoC: Amlogic **A311D**（g12b，`amlogic-dt-id = "g12b_w400_b"`）
- 家族: `meson-g12b` / 内核家族 `meson64`，主线 **6.18.52**（`current` 分支）
- 参考设计: Khadas VIM3（同 SoC），`BOOTCONFIG` 直接复用其 defconfig
- 框架: armbian/build **26.11.0-trunk**（26.x 新版 CLI）

**已实跑验证**：u-boot(`0:53`) → 内核(`51:15`) → 完整镜像(`8:59`)，镜像内
`/boot/dtb/amlogic/meson-g12b-a311d-pro-a311d.dtb`（77,055 B）已 loop 挂载确认。
**未做真机验证**的部分见 [docs/porting-notes.md](docs/porting-notes.md) 第四节。

---

## 一键云端编译

Actions 页面 → **build** → **Run workflow**：

| 输入 | 说明 |
|---|---|
| `artifact` | `build` 全镜像 / `kernel-dtb` 只编设备树(几分钟) / `kernel` 内核 deb / `uboot` |
| `branch` | `current`(默认) / `edge` |
| `release` | `bookworm`(默认) / `noble` / `trixie` |
| `build_ref` | armbian/build 的分支 / 标签 / commit SHA，默认 `main` |
| `create_release` | 完成后建 Release 并上传 `.img.xz` / `.deb`（默认开） |

想先确认落点对不对，先跑一次 `kernel-dtb`（几分钟），再跑 `build`。

`push` 到 `main` 只跑 **validate**（秒级）：查 LF 行尾、FIP 树完整性、`blx_fix.sh` 的
`+x` 位、脚本/YAML 语法、dts 关键节点。这些故障**全是静默的**，所以单独固化成检查。

> 公开仓库跑 Actions 不消耗额度。一次全量约 2.5 小时（4 核 runner），
> 所以 `push` 不自动触发全量——改一行 dts 烧两小时不合理。要持续集成就把
> `build` job 的 `if` 条件加上 `github.event_name == 'push'`。

## 本地编译

```bash
git clone https://github.com/iorca/pro-a311d-armbian.git && cd pro-a311d-armbian

bash scripts/deploy-to-build.sh ~/armbian-build      # ① 落 overlay（幂等，带自检）
bash scripts/build.sh kernel-dtb ~/armbian-build     # ② 只编设备树，几分钟
bash scripts/build.sh build ~/armbian-build          # ③ 全量镜像
bash scripts/verify-output.sh ~/armbian-build        # ④ 验收（编完必跑）
```

`~/armbian-build` 是 armbian/build 的 clone（`main` 分支即可）。
产物在 `~/armbian-build/output/{debs,images}/`。

**不要用 root/sudo 跑 `build.sh`**——终端里 stdin 是 tty，框架对 root 会倒计时然后退出。
CI 里相反（stdin 非 tty，root 照跑），所以 workflow 用的是 `sudo -E`。详见
[第五节 5.3](docs/porting-notes.md)。

---

## 目录结构 / 三个注入点

**全部落在 `userpatches/`，上游 armbian/build 一个字节都不改。**

```
userpatches/
├── config/boards/pro-a311d.conf                            ① 板级配置
└── config/sources/families/meson-g12b.conf                  ② 覆盖 FIP 打包入口
dts/meson-g12b-a311d-pro-a311d.dts                           ③ 设备树 master 副本
fip/pro-a311d/                                               ④ 厂商 FIP 树（19 文件 2.79 MB）
scripts/{deploy-to-build,build,verify-output}.sh
.github/workflows/build.yml
docs/porting-notes.md                                        完整适配记录与踩坑
```

| # | 机制 | 源码依据 |
|---|---|---|
| ① | `config_source_board_file()` 搜两个路径：`${SRC}/config/boards` + `${USERPATCHES_PATH}/config/boards` | `lib/functions/main/config-prepare.sh:100` |
| ② | family 配置同理搜两个路径，**core 先 source、userpatches 后 source，同 shell 内后定义覆盖前定义** → 整体重定义 `uboot_custom_postprocess()` | `lib/functions/configuration/main-config.sh:582` |
| ③ | 裸 `.dts` 放 `userpatches/kernel/<KERNELPATCHDIR>/dt/` → autopatcher 拷进源码树 + **自动改 Makefile**，不用做 patch 文件 | `lib/tools/common/dt_makefile_patcher.py` |
| ④ | FIP 树必须在 `cache/` 之外 | 见下 |

### ④ 为什么 FIP 树必须放 `cache/` 之外

`meson64_common.inc` 的 `fetch_sources_tools__libreelec_amlogic_fip()` 会
`fetch_from_repo LibreELEC/amlogic-boot-fip` 到 `$SRC/cache/sources/amlogic-boot-fip`，
而 `fetch_from_repo` 会 **`git clean` 掉该目录下所有未跟踪内容**。
LibreELEC 仓库里没有 `pro-a311d/`，所以拷进去的自定义 FIP 树每次构建都被删。

症状：`uboot_g12_postprocess` 报 `.../pro-a311d/blx_fix.sh: No such file or directory`（Error 127）。

本仓库把 FIP 放在仓库内 `fip/pro-a311d/`，`deploy-to-build.sh` 拷到 `${SRC}/fip/pro-a311d`，
board conf 用 `FIP_TREE_PRO_A311D="${FIP_TREE_PRO_A311D:-${SRC}/fip/pro-a311d}"` 指过去。
想指自己的目录：`export FIP_TREE_PRO_A311D=/your/amlogic-boot-fip/pro-a311d`。

---

## 维护

**改 dts**：只改 `dts/meson-g12b-a311d-pro-a311d.dts`（唯一 master 副本），重新跑
`deploy-to-build.sh` + 编译。不要直接改 armbian-build 里的副本。

**内核升大版本**（`meson64-6.18` → `meson64-6.19`）：**不用改任何东西**。
`deploy-to-build.sh` 会 awk 解析 `meson64_common.inc` 的 `case $BRANCH` 拿到
`KERNEL_MAJOR_MINOR`，再拼出 `archive/meson64-<MAJOR.MINOR>`，**不写死版本号**。
它还会断言上游 `patch/kernel/<该目录>/0000.patching_config.yaml` 存在——不存在就
**报错退出**，而不是静默落一个不生效的位置。

**上游漂移导致构建失败**：先看 `build_ref` 那个 commit 有没有改
`meson64_common.inc` / `meson-g12b.conf` / `0000.patching_config.yaml`。
`userpatches` 覆盖层只碰一个函数，不承担上游重构的风险；如果上游真实现了
`FIP_TREE_BOARD/FIP_TREE_FAMILY`（源码里有这条 `@TODO`），可以删掉 ② 那个文件。

**FIP 树**：`fip/pro-a311d/` 里 `blx_fix.sh` 与 `aml_encrypt_g12b` 必须是
**mode 100755**。Windows 上 `git add` 会丢 `+x` 位（NTFS 没这个位），必须：

```bash
git update-index --chmod=+x fip/pro-a311d/blx_fix.sh fip/pro-a311d/aml_encrypt_g12b
```

validate job 会查这个，丢了直接报错。

**仓库已设 `.gitattributes` 强制 LF**。Git for Windows 默认 `core.autocrlf=true`，会把
`.dts` / `.conf` / `Makefile` checkout 成 CRLF，导致 dtc 报错、`git apply` 拒绝、
Kconfig 混入 `^M` —— 全是静默故障。自检 `git ls-files --eol` 应全是 `i/lf`。

---

## 验收判据（不要靠肉眼看日志）

armbian 26.x 的 artifact 缓存会在**零报错**的情况下让镜像缺本板 dtb：补丁哈希没变
→ 命中 ORAS 远程缓存 → 本地连编都不编，镜像照样 2.4 G 出得来，只有上板才发现起不来。

`scripts/verify-output.sh` 固化这五层判据：

1. `linux-dtb-*-meson64_*.deb` 里含本板 dtb（`dpkg-deb -c | grep`）
2. `BOOT_FDT_FILE` 与 deb 内 dtb 文件名一致
3. 内核 worktree 里有 dts、**纯 LF**、与仓库 master 副本 md5 一致、Makefile 已被 autopatch
4. 镜像 loop 挂载后 `/boot/dtb/amlogic/` 真的有它，且 `armbianEnv.txt` 的 `fdtfile` 指得到
5. `linux-u-boot-pro-a311d-*.deb` 里的 `u-boot.bin` 含 `@AML` + `AMLIFPG` magic，体积 ~1.18 MB

CI 里第 4 步也会跑（root + losetup），失败即整个 job 红。

---

## 已知待真机核对

以下 **不影响编译**，dts 里已留注释/占位，但需底板原理图或真机才能定论：

- 内部 PHY (RMII) link-up；不通则查 `phy-mode` 与 `eth_phy` mdio-mux
- HDMI 热插拔；HDMI 5V 是否常开（否则需补 `hdmi-supply`）
- BT（AP6256, `brcm,bcm4345c5`）三脚极性
- **DVFS**：大核 PWM 通道路由（PWM AB ch0/GPIOA_E vs PWM AO CD ch0）、
  `voltage-table` 极性（当前按 vendor W400 反相）——**极性反了 = 高压低配**
- SD 卡 `CARD_DET` 启动电平（避免 romcode 误从 SD 启动）
- `BOOTCONFIG` 暂用 `khadas-vim3_defconfig`；要干净需从厂商 u-boot 派生独立 defconfig

完整清单见 [docs/porting-notes.md](docs/porting-notes.md) 第四节。

---

## 许可与第三方二进制

- 本仓库的脚本 / 配置 / dts：跟 armbian/build 一致，**GPL-2.0**。
  dts 头部为 `SPDX-License-Identifier: (GPL-2.0+ OR MIT)`（沿用内核 DT 惯例）。
- `fip/pro-a311d/` 内是 **Amlogic 厂商二进制**（`bl2.bin` / `bl30.bin` / `bl31.img` /
  `aml_encrypt_g12b` / DDR 固件等），随板卡 SDK 分发，**按原样再分发**，不在本仓库
  的 GPL 授权范围内。
