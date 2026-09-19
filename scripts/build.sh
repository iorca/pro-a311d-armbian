#!/usr/bin/env bash
# ============================================================================
# 本地编译启动器 (在**终端**里用)
#
# 用法:
#   bash scripts/build.sh [artifact] [armbian-build 目录] [BRANCH] [RELEASE]
#
#   artifact: build (默认) | kernel | kernel-dtb | uboot
#   BRANCH  : current (默认) | edge
#   RELEASE : bookworm (默认) | noble | trixie
#
# 例:
#   bash scripts/build.sh kernel-dtb ~/armbian-build
#   bash scripts/build.sh build ~/armbian-build current bookworm
#
# 前置: 先跑 scripts/deploy-to-build.sh 落 overlay。
#
# !! 本脚本强制 uid != 0。终端里 stdin 是 tty, 框架对 root 会走 10 秒倒计时然后退出
#    (lib/functions/cli/utils-cli.sh: cli_standard_relaunch_docker_or_sudo)。
#    普通用户跑时框架自己 sudo --preserve-env 重新拉起, 需要本机 sudo 免密。
#    CI 里情况相反 (stdin 非 tty, root 照跑), 直接用 sudo -E 调 compile.sh, 不走本脚本。
# ============================================================================

set -euo pipefail

ARTIFACT="${1:-build}"
AB="${2:-$HOME/armbian-build}"
BRANCH="${3:-current}"
RELEASE="${4:-bookworm}"

die() { printf '\n\033[31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

case "${ARTIFACT}" in
	build|kernel|kernel-dtb|uboot) ;;
	*) die "artifact 只能是 build / kernel / kernel-dtb / uboot, 收到 '${ARTIFACT}'" ;;
esac

if [[ "$(id -u)" == "0" ]]; then
	die "不要以 root/sudo 运行本脚本。
       终端里 stdin 是 tty → 框架会对 root 走倒计时后退出。
       正确做法: 用普通用户跑; 框架内部会自己 sudo。
       若你是要在 CI 里跑, 见 .github/workflows/build.yml (那里用 sudo -E)。"
fi

AB="$(cd "${AB}" && pwd)" 2>/dev/null || die "armbian-build 目录不存在: ${AB}"
[[ -x "${AB}/compile.sh" ]] || die "${AB}/compile.sh 不存在或不可执行"
[[ -d "${AB}/userpatches/config/boards" ]] || die "${AB} 里没有 userpatches —— 还没落 overlay? 先跑 scripts/deploy-to-build.sh"

# 落点是否已就位（免得白等两小时才发现 dts 没进去）
BOARD_CONF="${AB}/userpatches/config/boards/pro-a311d.conf"
[[ -f "${BOARD_CONF}" ]] || die "${BOARD_CONF} 不存在 —— 先跑 scripts/deploy-to-build.sh ${AB}"
if ! ls "${AB}"/userpatches/kernel/*/dt/meson-g12b-a311d-pro-a311d.dts >/dev/null 2>&1; then
	die "userpatches/kernel/*/dt/ 下没有本板 dts —— 先跑 scripts/deploy-to-build.sh ${AB}"
fi

# 非交互门控: 必须 export。放命令行会被 CLI 白名单静默丢弃
# (判据: 日志 Repeat Build Options 行里看不到它们)。
export EXPERT=yes
export KERNEL_CONFIGURE=no
export UBOOT_CONFIGURE=no
export BUILD_DESKTOP="${BUILD_DESKTOP:-no}"
export BUILD_MINIMAL="${BUILD_MINIMAL:-no}"   # BUILD_DESKTOP=no 时仍需本变量非空

LOG="/tmp/pro-a311d-${ARTIFACT}-$(date +%Y%m%d-%H%M%S).log"

printf '\n\033[1m=== PRO-A311D 本地编译 ===\033[0m\n'
printf '  artifact : %s\n' "${ARTIFACT}"
printf '  AB       : %s\n' "${AB}"
printf '  BRANCH   : %s   RELEASE: %s\n' "${BRANCH}" "${RELEASE}"
printf '  log      : %s\n\n' "${LOG}"

cd "${AB}"

# 前台跑 + tee 到日志: 中途 Ctrl-C 能干净退出, 且事后有完整日志可查。
# 别用 `setsid ... &` —— 本地前台跑不需要它, 反而容易误判"启动失败"。
set +e
./compile.sh "${ARTIFACT}" BOARD=pro-a311d BRANCH="${BRANCH}" RELEASE="${RELEASE}" 2>&1 | tee "${LOG}"
RC="${PIPESTATUS[0]}"
set -e

printf '\n=== compile.sh 退出码 %d ===\n' "${RC}"
if [[ "${RC}" != "0" ]]; then
	printf '\033[31m编译失败。\033[0m 看日志: %s\n' "${LOG}"
	printf '常见原因:\n'
	printf '  - 上游改了 config/sources/families/include/meson64_common.inc 结构 → 落点派生失败\n'
	printf '  - 网络: github / ghcr 不可达 (见 docs/porting-notes.md 网络一节)\n'
	exit "${RC}"
fi

printf '\n\033[32m编译完成。\033[0m 现在**必须**跑验收:\n'
printf '  bash %s/scripts/verify-output.sh %s\n\n' "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" "${AB}"
