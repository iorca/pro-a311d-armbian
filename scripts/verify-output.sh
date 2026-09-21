#!/usr/bin/env bash
# ============================================================================
# PRO-A311D 产物验收 —— 编完之后跑这个，不要靠肉眼看日志。
#
# 用法:
#   bash scripts/verify-output.sh <armbian-build 目录> [board]
#
# 为什么需要它:
#   armbian 26.x 的 artifact 缓存会在**零报错**的情况下让镜像缺本板 dtb
#   （补丁哈希没变 → 命中 ORAS 远程缓存 → 本地连编都不编）。
#   镜像照样 2.4G 出得来，只有上板才发现起不来。所以必须机器判据。
#
# 判据:
#   ① linux-dtb deb 里有本板 dtb                  ← 编的时候就决定了的
#   ② BOOT_FDT_FILE 与 deb 内 dtb 文件名一致       ← 板级 conf 拼写
#   ③ 内核源码树里有 dts + 纯 LF + Makefile 加行    ← 落点机制生效
#   ④ 镜像里的 /boot/dtb/amlogic/ 真的有它          ← 端到端
#   ⑤ u-boot deb 里是真 FIP (AML magic + 体积)     ← u-boot 侧
# ============================================================================

set -uo pipefail

AB="${1:?用法: bash scripts/verify-output.sh <armbian-build 目录> [board]}"
BOARD="${2:-pro-a311d}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AB="$(cd "${AB}" && pwd)" || { echo "ERROR: 目录不存在"; exit 2; }

PASS=0; FAIL=0; SKIP=0
ok()   { printf '  \033[32m[ok]\033[0m   %s\n' "$*"; PASS=$((PASS+1)); }
bad()  { printf '  \033[31m[FAIL]\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }
skip() { printf '  \033[33m[skip]\033[0m %s\n' "$*"; SKIP=$((SKIP+1)); }
head_() { printf '\n\033[1m===== %s =====\033[0m\n' "$*"; }

# ---------------------------------------------------------------------------
# 期望的 dtb 文件名从落点的 board conf 读，不在本脚本里重复写一遍 ——
# 两处写死就会漂移，而漂移的后果在这里恰恰是最危险的（验收脚本自己错了就白验）。
# ---------------------------------------------------------------------------
CONF="${AB}/userpatches/config/boards/${BOARD}.conf"
EXPECT_FDT=""
[[ -f "${CONF}" ]] && EXPECT_FDT="$(sed -n 's/^BOOT_FDT_FILE="\(.*\)".*/\1/p' "${CONF}" | head -1)"

DTB_NAME="$(basename "${EXPECT_FDT:-amlogic/${BOARD}.dtb}")"
DTS_NAME="${DTB_NAME%.dtb}.dts"

head_ "0. 基本信息"
echo "  armbian-build : ${AB}"
echo "  board         : ${BOARD}"
echo "  BOOT_FDT_FILE : ${EXPECT_FDT:-（读不到，回退 ${DTB_NAME}）}"
echo "  期望 dtb 名   : ${DTB_NAME}"

# ---------------------------------------------------------------- ① dtb in deb
head_ "① linux-dtb deb 里是否有本板 dtb"
DTB_DEB="$(ls -t "${AB}"/output/debs/linux-dtb-*-meson64_*.deb 2>/dev/null | head -1)"
if [[ -z "${DTB_DEB}" ]]; then
	skip "没找到 linux-dtb-*-meson64_*.deb（还没编?）"
else
	echo "  deb: $(basename "${DTB_DEB}")  ($(du -h "${DTB_DEB}" | cut -f1))"
	PHASH="$(basename "${DTB_DEB}" | grep -o 'P[0-9a-f]\{4\}' | head -1 || true)"
	[[ -n "${PHASH}" ]] && echo "  补丁哈希 P 段: ${PHASH}   （没变 = userpatches 没进哈希 = 走的远程缓存）"

	LISTING="$(dpkg-deb -c "${DTB_DEB}" 2>/dev/null || true)"
	CNT="$(printf '%s\n' "${LISTING}" | grep -c "${DTB_NAME}$" || true)"
	if [[ "${CNT:-0}" -ge 1 ]]; then
		ok "deb 内含 ${DTB_NAME} × ${CNT}"
		printf '%s\n' "${LISTING}" | grep "${DTB_NAME}$" | sed 's/^/       /'
	else
		bad "deb 内没有 ${DTB_NAME} —— 这就是「镜像编出来了但上板起不来」那个坑。

       根因通常是 dts 落点目录 != 实际 KERNELPATCHDIR
       （实际是 archive/<family>-<MAJOR.MINOR>，不是 archive/meson64-current）。
       自检:
         ls    ${AB}/userpatches/kernel/
         grep  'User patches directory' ${AB}/output/logs/*/* 2>/dev/null | tail -3"

		# 给出实际有哪些 dtb，便于肉眼对比是不是名字写错
		printf '%s\n' "${LISTING}" | grep -oE '[^/]+\.dtb$' | sort -u | head -10 | sed 's/^/       实际含: /'
	fi

	if [[ -n "${EXPECT_FDT}" && "${CNT:-0}" -ge 1 ]]; then
		ok "BOOT_FDT_FILE 与 deb 内 dtb 一致"
	fi
fi

# --------------------------------------------------------------- ② 源码树
head_ "② 内核源码树 (落点机制是否生效)"
WT="$(ls -d "${AB}"/cache/sources/linux-kernel-worktree/*__meson64__arm64 2>/dev/null | head -1)"
if [[ -z "${WT}" ]]; then
	skip "没有 meson64 worktree —— 内核是从 ORAS 远程缓存拉的（本地根本没编）"
else
	echo "  worktree: $(basename "${WT}")"
	F="${WT}/arch/arm64/boot/dts/amlogic/${DTS_NAME}"
	if [[ -f "${F}" ]]; then
		ok "源码树内有 ${DTS_NAME} ($(stat -c%s "${F}") B)"
	else
		bad "源码树内没有 ${DTS_NAME}"
	fi
	if [[ -f "${F}" ]]; then
		if grep -qU $'\r' "${F}"; then
			bad "dts 含 CRLF (0x0d) —— .gitattributes 没生效；dtc 出错或污染 dtb"
		else
			ok "dts 是纯 LF"
		fi
		# 与仓库 master 副本逐字节比对
		MAS="${REPO_ROOT}/dts/${DTS_NAME}"
		if [[ -f "${MAS}" ]]; then
			A="$(md5sum "${MAS}" | cut -d' ' -f1)"
			B="$(md5sum "${F}"   | cut -d' ' -f1)"
			[[ "${A}" == "${B}" ]] && ok "与仓库 master 副本 md5 一致 (${A})" \
				|| bad "与仓库 master 副本不一致 (repo=${A} tree=${B}) —— 源码树里的是旧版?"
		else
			skip "仓库里没有 dts/${DTS_NAME} 可比对"
		fi
	fi
	MK="${WT}/arch/arm64/boot/dts/amlogic/Makefile"
	if grep -q "dtb-.*${DTB_NAME%.dtb}\.dtb" "${MK}" 2>/dev/null; then
		ok "Makefile 已由 autopatcher 自动加行"
	else
		bad "Makefile 里没有 ${DTB_NAME} 那一行"
	fi
fi

# ------------------------------------------------------------------- ③ image
head_ "③ 镜像里的 /boot/dtb/amlogic/"
# armbian 生成的文件名里 board 是**首字母大写**的（board=pro-a311d → 文件名 Pro-a311d），
# 跟 ${BOARD} 变量的大小写对不上。这里曾经写的是 *"${BOARD}"*.img，
# 结果这一项**永远 skip** —— "镜像里到底有没有本板 dtb"这个端到端判据静默失效，
# 比没有还糟（看着像验过了）。必须大小写不敏感（-iname），并按下述规则取最新产物。
IMG_DIR="${AB}/output/images"
pick_newest() { # $1 = 后缀 glob，如 '.img'
	find "${IMG_DIR}" -maxdepth 1 -iname "*${BOARD}*$1" -printf '%T@\t%p\n' 2>/dev/null |
		sort -rn | head -1 | cut -f2-
}
IMG="$(pick_newest '.img')"
IMGXZ="$(pick_newest '.img.xz')"
# 谁新用谁：磁盘上可能还躺着上一次的旧 .img，不能让它替这次新出的 .img.xz 作证
if [[ -n "${IMGXZ}" && ( -z "${IMG}" || "${IMGXZ}" -nt "${IMG}" ) ]]; then IMG=""; fi

if [[ -n "${IMG}" ]]; then
	echo "  镜像: $(basename "${IMG}")  ($(du -h "${IMG}" | cut -f1))"
	if [[ "$(id -u)" != "0" ]]; then
		skip "非 root，无法 losetup（sudo 重跑可解锁这一项）"
	elif ! command -v losetup >/dev/null 2>&1; then
		skip "没有 losetup"
	else
		LOOP="$(losetup -Pf --show "${IMG}" 2>/dev/null || true)"
		if [[ -z "${LOOP}" ]]; then
			bad "losetup 挂不上镜像"
		else
			MNT="$(mktemp -d)"
			if mount -o ro "${LOOP}p1" "${MNT}" 2>/dev/null; then
				if [[ -f "${MNT}/boot/dtb/amlogic/${DTB_NAME}" ]]; then
					ok "/boot/dtb/amlogic/${DTB_NAME} 存在 ($(stat -c%s "${MNT}/boot/dtb/amlogic/${DTB_NAME}") B)"
				else
					bad "/boot/dtb/amlogic/${DTB_NAME} 不存在 —— 上板起不来！
       实际内容: $(ls "${MNT}/boot/dtb/amlogic/" 2>/dev/null | tr '\n' ' ')"
				fi
				if [[ -f "${MNT}/boot/armbianEnv.txt" ]]; then
					FF="$(sed -n 's/^fdtfile=\(.*\)/\1/p' "${MNT}/boot/armbianEnv.txt" | head -1)"
					if [[ -n "${FF}" && -f "${MNT}/boot/dtb/${FF}" ]]; then
						ok "armbianEnv.txt 的 fdtfile=${FF} 能对上实体文件"
					else
						bad "armbianEnv.txt 的 fdtfile='${FF:-（空）}' 找不到对应 dtb"
					fi
				else
					bad "镜像里没有 /boot/armbianEnv.txt"
				fi
				umount "${MNT}"
			else
				bad "mount ${LOOP}p1 失败"
			fi
			rmdir "${MNT}" 2>/dev/null || true
			losetup -d "${LOOP}" 2>/dev/null || true
		fi
	fi
elif [[ -n "${IMGXZ}" ]]; then
	echo "  镜像(压缩): $(basename "${IMGXZ}")  ($(du -h "${IMGXZ}" | cut -f1))"
	skip "最新产物是 .img.xz，跳过挂载实测（要端到端验证: xz -dc 解出来再 sudo 重跑本项）"
else
	skip "output/images/ 里没有本板镜像（匹配 *${BOARD}*.img / *.img.xz，大小写不敏感）"
fi

# ------------------------------------------------------------------ ④ u-boot
head_ "④ u-boot deb 是否是真 FIP"
UB_DEB="$(ls -t "${AB}"/output/debs/linux-u-boot-"${BOARD}"-*.deb 2>/dev/null | head -1)"
if [[ -z "${UB_DEB}" ]]; then
	skip "没找到 linux-u-boot-${BOARD}-*.deb"
else
	echo "  deb: $(basename "${UB_DEB}")  ($(du -h "${UB_DEB}" | cut -f1))"
	TMP="$(mktemp -d)"
	dpkg-deb -x "${UB_DEB}" "${TMP}" 2>/dev/null
	UBBIN="$(find "${TMP}" -name 'u-boot.bin' 2>/dev/null | head -1)"
	if [[ -z "${UBBIN}" ]]; then
		bad "deb 里没有 u-boot.bin"
	else
		SZ="$(stat -c%s "${UBBIN}")"
		echo "  u-boot.bin: ${SZ} B"
		grep -qa '@AML'    "${UBBIN}" && ok "含 @AML magic"    || bad "没有 @AML magic —— 不是 Amlogic FIP"
		grep -qa 'AMLIFPG' "${UBBIN}" && ok "含 AMLIFPG magic" || bad "没有 AMLIFPG magic"
		if [[ "${SZ}" -gt 1000000 && "${SZ}" -lt 2000000 ]]; then
			ok "体积在预期范围 (实测参考 ~1,184,112 B)"
		else
			bad "体积 ${SZ} B 偏离预期 (~1,184,112 B) —— FIP 可能没组装全 (ddrfw 缺失?)"
		fi
	fi
	rm -rf "${TMP}"
fi

# ------------------------------------------------------------------- 汇总
head_ "汇总"
printf '  通过 %d / 失败 %d / 跳过 %d\n\n' "${PASS}" "${FAIL}" "${SKIP}"
if [[ "${FAIL}" -gt 0 ]]; then
	printf '  \033[31m验收不通过 —— 别烧这块镜像。\033[0m\n'
	exit 1
fi
printf '  \033[32m验收通过。\033[0m\n'
exit 0
