#!/usr/bin/env bash
# ============================================================================
# PRO-A311D overlay → armbian/build 落点脚本
#
# 幂等。CI (.github/workflows/build.yml) 与本地开发共用这一份，避免两处漂移。
#
# 用法:
#   bash scripts/deploy-to-build.sh [--dry-run] [--branch <current|edge>] <armbian-build 目录>
#
# 例:
#   bash scripts/deploy-to-build.sh ~/armbian-build
#   bash scripts/deploy-to-build.sh --dry-run --branch edge /srv/armbian-build
#
# 环境变量:
#   KERNELPATCHDIR   显式指定补丁目录, 跳过自动派生 (逃生舱, 见下)
#   FIP_TREE_PRO_A311D  留给编译期, 不在本脚本用 —— 本脚本总是把仓库里的
#                       fip/ 拷到 <AB>/fip/, 也就是 board conf 的默认值。
#
# 落三处 (全部走 userpatches，不碰上游文件):
#
#   1) userpatches/                → <AB>/userpatches/
#        config/boards/pro-a311d.conf                    板级配置
#        config/sources/families/meson-g12b.conf         覆盖 uboot_custom_postprocess()
#
#   2) dts/meson-g12b-a311d-pro-a311d.dts
#                                 → <AB>/userpatches/kernel/archive/meson64-<MAJOR.MINOR>/dt/
#        目录名**从上游源码派生**，不写死。写死就是那个致命坑:
#        KERNELPATCHDIR 实际是 archive/<family>-<MAJOR.MINOR> (由 case $BRANCH 决定)，
#        不是 archive/meson64-current。放错 → dts 根本不被读 + 补丁哈希不变
#        → 静默命中 ORAS 远程缓存 → 镜像编得出来但里面没有本板 dtb → 上板起不来。
#
#   3) fip/pro-a311d/              → <AB>/fip/pro-a311d/
#        必须在 cache/ 之外，否则被 fetch_from_repo 的 git clean 删掉。
# ============================================================================

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

BOARD="pro-a311d"
BOARD_DTS="meson-g12b-a311d-pro-a311d.dts"
LINUXFAMILY="meson64"   # meson-g12b 家族被 family conf 改写成 meson64 (deb/worktree 都按这个命名)

# ---------------------------------------------------------------- 参数解析
DRY_RUN="no"
BRANCH="current"
AB=""

while [[ $# -gt 0 ]]; do
	case "$1" in
		--dry-run) DRY_RUN="yes"; shift ;;
		--branch)  BRANCH="${2:?--branch 需要一个值}"; shift 2 ;;
		--help|-h)
			sed -n '2,32p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
			exit 0 ;;
		-*) echo "ERROR: 未知参数 '$1'" >&2; exit 2 ;;
		*) AB="$1"; shift ;;
	esac
done

if [[ -z "${AB}" ]]; then
	echo "ERROR: 缺少 armbian-build 目录参数。" >&2
	echo "用法: bash scripts/deploy-to-build.sh [--dry-run] [--branch current] <armbian-build 目录>" >&2
	exit 2
fi

say()  { printf '%s\n' "$*"; }
step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
die()  { printf '\n\033[31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

# ------------------------------------------------ 派生 KERNEL_MAJOR_MINOR
# 来源: config/sources/families/include/meson64_common.inc
#       case $BRANCH in
#           oldlts)       KERNEL_MAJOR_MINOR="6.12" ;;
#           current)      KERNEL_MAJOR_MINOR="6.18" ;;   ← current 是 6.18, 不是"最新"
#           edge)         KERNEL_MAJOR_MINOR="7.2"  ;;
#           bleedingedge) KERNEL_MAJOR_MINOR="7.3"  ;;
#       esac
# 然后 config/sources/common.conf:127
#       KERNELPATCHDIR="archive/${KERNEL_PATCH_ARCHIVE_BASE}-${KERNEL_MAJOR_MINOR}"
#   （KERNEL_PATCH_ARCHIVE_BASE 未设时回退 LINUXFAMILY = meson64）
derive_kernel_major_minor() {
	local inc="$1" branch="$2"

	[[ -f "${inc}" ]] || die "找不到 ${inc} —— 这不是一个 armbian/build 树?"

	local mm
	mm="$(awk -v br="${branch}" '
		/^[[:space:]]*case[[:space:]]+\$BRANCH[[:space:]]+in/ { inblk = 1; next }
		inblk && /^[[:space:]]*esac/ { inblk = 0 }
		inblk && $0 ~ ("^[[:space:]]*" br "\\)") { hit = 1 }
		hit && match($0, /KERNEL_MAJOR_MINOR="[0-9]+\.[0-9]+"/) {
			s = substr($0, RSTART, RLENGTH); gsub(/[^0-9.]/, "", s); print s; exit
		}
	' "${inc}")"

	[[ -n "${mm}" ]] || die "无法从 ${inc} 的 case \$BRANCH 里解析出 BRANCH='${branch}' 的 KERNEL_MAJOR_MINOR" \
		"（上游可能改了结构。手动确认后可用 KERNELPATCHDIR 环境变量先行绕过。）"

	printf '%s' "${mm}"
}

# ------------------------------------------------------------------- 前置检查
step "0/4 检查输入"

[[ -f "${REPO_ROOT}/userpatches/config/boards/${BOARD}.conf" ]] \
	|| die "缺 ${REPO_ROOT}/userpatches/config/boards/${BOARD}.conf"
[[ -f "${REPO_ROOT}/userpatches/config/sources/families/meson-g12b.conf" ]] \
	|| die "缺 meson-g12b.conf 覆盖文件"
[[ -f "${REPO_ROOT}/dts/${BOARD_DTS}" ]] \
	|| die "缺 ${REPO_ROOT}/dts/${BOARD_DTS}"
[[ -d "${REPO_ROOT}/fip/${BOARD}" ]] \
	|| die "缺 ${REPO_ROOT}/fip/${BOARD}/ (FIP 树)"

AB="$(cd "${AB}" && pwd)" || die "armbian-build 目录不存在: ${AB}"
[[ -f "${AB}/compile.sh" ]] || die "${AB} 里没有 compile.sh —— 不是 armbian/build 树?"

# userpatches/ 在 armbian/build 的 git 仓库里**不存在**，fresh clone 之后不会有这个目录。
# 证据: .gitignore 第 19 行是 `/userpatches`，`git ls-files userpatches` 返回 0 个文件，
#       `git ls-tree HEAD userpatches/` 为空。
# 它由 armbian 运行时自己创建:
#   lib/functions/cli/entrypoint.sh:128   mkdir -p "${DEST}" "${USERPATCHES_PATH}"
#   lib/functions/host/prepare-host.sh:95 mkdir -p ... "${USERPATCHES_PATH}" ...
# 我们在 compile.sh 之前就要往里落 overlay，所以必须自己先建出来。
#
# 踩过: 这里原先是 `[[ -d "${AB}/userpatches" ]] || die ...`。
# 本机（跑过编译，armbian 早替我们建好了）永远不会触发；CI fresh clone 上 100% 触发，
# 表现为 build job 的"落 overlay"步骤 0 秒 exit 1，编译和验收被 skip。
# 教训: 断言"上游树里有什么"之前，先想清楚它是不是 gitignore 的 —— 本地有、clone 后没有。
mkdir -p "${AB}/userpatches"

# 逃生舱: 环境变量 KERNELPATCHDIR 显式指定时直接用, 不做派生
# （上游把 meson64_common.inc 结构大改、派生失败时, 先用它跑通, 再回头修派生逻辑）
MAJMIN=""   # 显式初始化 —— 覆盖分支不派生它, 但下面的报错信息会引用, set -u 下不能是未定义
if [[ -n "${KERNELPATCHDIR:-}" ]]; then
	PATCHDIR="${KERNELPATCHDIR}"
	PATCHDIR_NOTE="由环境变量 KERNELPATCHDIR 显式指定"
else
	MAJMIN="$(derive_kernel_major_minor "${AB}/config/sources/families/include/meson64_common.inc" "${BRANCH}")"
	PATCHDIR="archive/${LINUXFAMILY}-${MAJMIN}"
	PATCHDIR_NOTE="派生自 meson64_common.inc 的 case \$BRANCH: KERNEL_MAJOR_MINOR=${MAJMIN}"
fi
CORE_YAML="${AB}/patch/kernel/${PATCHDIR}/0000.patching_config.yaml"
DTS_DST_DIR="${AB}/userpatches/kernel/${PATCHDIR}/dt"

say "  armbian-build : ${AB}"
say "  BRANCH        : ${BRANCH}"
say "  KERNELPATCHDIR: ${PATCHDIR}   (${PATCHDIR_NOTE})"
say "  dts 落点      : ${DTS_DST_DIR}/${BOARD_DTS}"
say "  FIP 落点      : ${AB}/fip/${BOARD}"

if [[ ! -f "${CORE_YAML}" ]]; then
	say ""
	die "上游缺 ${CORE_YAML}" \
		"该文件提供 dts-directories + auto-patch-dt-makefile 声明，没有它 dts 不会被拷进内核源码树。" \
		"可能原因: 内核大版本升级后上游把目录改名了 (archive/meson64-${MAJMIN:-?} → ?)。" \
		"查: ls ${AB}/patch/kernel/archive/  然后调整本脚本的派生逻辑, 或用环境变量 KERNELPATCHDIR=<正确目录> 先跑通。"
fi

if [[ "${DRY_RUN}" == "yes" ]]; then
	step "dry-run: 到此为止，没有写任何文件"
	exit 0
fi

# --------------------------------------------------------------- 1) userpatches
step "1/4 落 userpatches/ (板级 conf + family 覆盖)"
cp -rv "${REPO_ROOT}/userpatches/." "${AB}/userpatches/"

# -------------------------------------------------------------------- 2) dts
step "2/4 落 dts → userpatches/kernel/${PATCHDIR}/dt/"
mkdir -p "${DTS_DST_DIR}"
cp -v "${REPO_ROOT}/dts/${BOARD_DTS}" "${DTS_DST_DIR}/${BOARD_DTS}"

# 清掉其它 kernel patch 目录下的同名旧副本 —— 内核升级换了 PATCHDIR 之后，
# 旧目录里残留的 dts 会让人误判"已经落好了"，实际那份根本不被读。
STALE="$(find "${AB}/userpatches/kernel" -name "${BOARD_DTS}" -not -path "*/${PATCHDIR}/dt/*" 2>/dev/null || true)"
if [[ -n "${STALE}" ]]; then
	say "  清理旧副本:"
	while IFS= read -r f; do
		[[ -z "${f}" ]] && continue
		say "    - ${f}"
		rm -f "${f}"
	done <<< "${STALE}"
fi

# -------------------------------------------------------------------- 3) FIP
step "3/4 落 FIP 树 → ${AB}/fip/${BOARD}/"
mkdir -p "${AB}/fip"
rm -rf "${AB}/fip/${BOARD}"
cp -r "${REPO_ROOT}/fip/${BOARD}" "${AB}/fip/${BOARD}"
chmod +x "${AB}/fip/${BOARD}/blx_fix.sh" "${AB}/fip/${BOARD}/aml_encrypt_g12b"
say "  $(find "${AB}/fip/${BOARD}" -type f | wc -l) 个文件"

# ------------------------------------------------------------------ 4) 自检
step "4/4 自检"

fail=0
check() { # <描述> <命令...>
	local desc="$1"; shift
	if "$@" >/dev/null 2>&1; then
		say "  [ok]   ${desc}"
	else
		say "  [FAIL] ${desc}"
		fail=1
	fi
}

check "dts 已就位且非空"            test -s "${DTS_DST_DIR}/${BOARD_DTS}"
check "board conf 已就位"           test -s "${AB}/userpatches/config/boards/${BOARD}.conf"
check "family conf 覆盖已就位"      test -s "${AB}/userpatches/config/sources/families/meson-g12b.conf"
check "family 覆盖里含函数重定义"   grep -q 'function uboot_custom_postprocess' \
	"${AB}/userpatches/config/sources/families/meson-g12b.conf"
check "FIP blx_fix.sh 可执行"       test -x "${AB}/fip/${BOARD}/blx_fix.sh"
check "FIP aml_encrypt_g12b 可执行" test -x "${AB}/fip/${BOARD}/aml_encrypt_g12b"
check "FIP 必需文件齐 (bl2/bl30/bl31)" bash -c \
	"for f in bl2.bin bl30.bin bl31.img acs.bin bl301.bin aml_ddr.fw; do [[ -e '${AB}/fip/${BOARD}/'\$f ]] || exit 1; done"

# 上游 core family conf 未被我们改动 (确认我们真的没碰上游文件)
if [[ -f "${AB}/config/sources/families/meson-g12b.conf" ]]; then
	if grep -q 'pro-a311d' "${AB}/config/sources/families/meson-g12b.conf"; then
		say "  [warn] 上游 config/sources/families/meson-g12b.conf 里出现了 'pro-a311d'"
		say "         —— 这是旧方案(现场插入 elif)留下的痕迹，本 overlay 不需要它。"
		say "         留着不致命(我们的 userpatches 覆盖在后)，但建议还原: git -C ${AB} checkout -- config/sources/families/meson-g12b.conf"
	fi
fi

if [[ "${fail}" != "0" ]]; then
	die "自检未通过，见上面 [FAIL] 行。"
fi

step "完成 —— 可以编译了"
say ""
say "  cd ${AB}"
say "  export EXPERT=yes KERNEL_CONFIGURE=no UBOOT_CONFIGURE=no BUILD_DESKTOP=no BUILD_MINIMAL=no"
say "  ./compile.sh uboot  BOARD=${BOARD} BRANCH=${BRANCH}"
say "  ./compile.sh kernel BOARD=${BOARD} BRANCH=${BRANCH}      # 先验 dtb 进包, 9 分钟"
say "  ./compile.sh build  BOARD=${BOARD} BRANCH=${BRANCH} RELEASE=bookworm"
say ""
say "  编完用 scripts/verify-output.sh 验收:"
say "  bash ${REPO_ROOT}/scripts/verify-output.sh ${AB} ${BOARD}"
say ""
