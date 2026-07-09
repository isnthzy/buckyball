#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: build-toy-u280-bitstream.sh [options]

Build the BuckyBall Toy FireSim bitstream for Xilinx Alveo U280.

Options:
  --reuse-existing       Do not launch Vivado; verify the newest existing Toy U280 firesim.tar.gz.
  --cfg DIR              Directory for generated FireSim YAML configs.
                         Default: /tmp/buckyball-firesim-toy-u280-$USER
  -h, --help             Show this help.

Environment overrides:
  VIVADO_SETTINGS                     Default: /nfs/tools/xilinx/2022.1/Vivado/2022.1/settings64.sh
  FIRESIM_XILINX_BOARD_REPO_PATHS     Default: $HOME/.cache/xilinx-board-files/open-nic-shell/board_files/Xilinx
EOF
}

die() {
  echo "error: $*" >&2
  exit 1
}

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
BB=$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)
FS="$BB/arch/thirdparty/chipyard/sims/firesim"
YAML_SRC="$BB/bbdev/api/steps/firesim/scripts/yaml"
MAKEFRAG="$BB/bbdev/api/steps/firesim/scripts/makefrag/firesim"
CFG="${BUCKYBALL_FIRESIM_CFG:-/tmp/buckyball-firesim-toy-u280-${USER:-user}}"
REUSE_EXISTING=0
ORIGINAL_ARGS=("$@")

while [[ $# -gt 0 ]]; do
  case "$1" in
    --reuse-existing)
      REUSE_EXISTING=1
      ;;
    --cfg)
      [[ $# -ge 2 ]] || die "--cfg requires a directory"
      CFG="$2"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
  shift
done

VIVADO_SETTINGS="${VIVADO_SETTINGS:-/nfs/tools/xilinx/2022.1/Vivado/2022.1/settings64.sh}"
FIRESIM_XILINX_BOARD_REPO_PATHS="${FIRESIM_XILINX_BOARD_REPO_PATHS:-$HOME/.cache/xilinx-board-files/open-nic-shell/board_files/Xilinx}"
FPGA_DB="${FIRESIM_FPGA_DB:-$FS/deploy/firesim-db.json}"

find_latest_toy_tar() {
  python3 - "$FS" <<'PY'
from pathlib import Path
import sys

root = Path(sys.argv[1]) / "deploy" / "results-build"
matches = list(root.glob("*alveo_u280_firesim_BuckyballToyConfig_no_nic*/**/firesim.tar.gz"))
if not matches:
    raise SystemExit(1)
latest = max(matches, key=lambda p: p.stat().st_mtime)
print(latest)
PY
}

verify_bitstream_tar() {
  local tarball="$1"
  [[ -f "$tarball" ]] || die "bitstream tar not found: $tarball"

  local contents
  contents=$(tar -tzf "$tarball")
  grep -qx "xilinx_alveo_u280/firesim.bit" <<<"$contents" || die "firesim.bit missing in $tarball"
  grep -qx "xilinx_alveo_u280/firesim.mcs" <<<"$contents" || die "firesim.mcs missing in $tarball"
  grep -qx "xilinx_alveo_u280/metadata" <<<"$contents" || die "metadata missing in $tarball"

  echo "Verified Toy U280 bitstream package:"
  echo "  $tarball"
  echo "Contains:"
  echo "$contents" | sed 's/^/  /'
}

ensure_firesim_env() {
  if [[ ! -f "$FS/env.sh" ]]; then
    cat > "$FS/env.sh" <<EOF
export FIRESIM_ENV_SOURCED=1
export FS_DIR=$FS
export RISCV=\${RISCV:-$BB/result}
export PATH="\$RISCV/bin:\$FS_DIR/deploy:\$PATH"
EOF
  fi
}

prepare_configs() {
  [[ -d "$YAML_SRC" ]] || die "missing FireSim YAML source dir: $YAML_SRC"
  [[ -d "$MAKEFRAG" ]] || die "missing FireSim makefrag dir: $MAKEFRAG"

  mkdir -p "$CFG"
  cp "$YAML_SRC"/config_*.yaml "$CFG"/

  export BB FS CFG MAKEFRAG FPGA_DB
  python3 - <<'PY'
from pathlib import Path
import os
import re

bb = os.environ["BB"]
fs = os.environ["FS"]
cfg = Path(os.environ["CFG"])
makefrag = os.environ["MAKEFRAG"]
fpga_db = os.environ["FPGA_DB"]

for path in cfg.glob("config_*.yaml"):
    text = path.read_text()
    text = text.replace("/home/mio/Code/buckyball", bb)
    text = text.replace("/home/wanghui/Code/buckyball", bb)
    text = text.replace("TARGET_PROJECT_MAKEFRAG: ../makefrag/firesim",
                        f"TARGET_PROJECT_MAKEFRAG: {makefrag}")
    path.write_text(text)

build = cfg / "config_build.yaml"
text = build.read_text()
text = re.sub(r"default_build_dir:\s*.*",
              f"default_build_dir: {fs}/deploy/FIRESIM_BUILD_DIR",
              text)
text = re.sub(
    r"builds_to_run:\n(?:(?:[ \t].*\n)+)",
    "builds_to_run:\n"
    "    # this section references builds defined in config_build_recipes.yaml\n"
    "    # if you add a build here, it will be built when you run buildbitstream\n"
    "    - alveo_u280_firesim_BuckyballToyConfig_no_nic\n\n",
    text,
    count=1,
)
build.write_text(text)

runtime = cfg / "config_runtime.yaml"
text = runtime.read_text()
text = re.sub(r"default_platform:\s*.*",
              "default_platform: XilinxAlveoU280InstanceDeployManager",
              text)
text = re.sub(r"default_simulation_dir:\s*.*",
              f"default_simulation_dir: {fs}/deploy/FIRESIM_RUNS_DIR",
              text)
text = re.sub(r"default_fpga_db:\s*.*",
              f"default_fpga_db: {fpga_db}",
              text)
text = re.sub(r"default_hw_config:\s*.*",
              "default_hw_config: alveo_u280_firesim_BuckyballToyConfig_no_nic",
              text)
runtime.write_text(text)
PY
}

enter_nix_if_needed() {
  if [[ -z "${BUCKYBALL_FIRESIM_IN_NIX:-}" ]] && ! command -v firesim >/dev/null 2>&1; then
    command -v nix >/dev/null 2>&1 || die "firesim is not in PATH and nix is unavailable"
    export BUCKYBALL_FIRESIM_IN_NIX=1
    cd "$BB"
    exec nix develop --command bash "$0" "$@"
  fi
}

source_tool_env() {
  [[ -f "$VIVADO_SETTINGS" ]] || die "Vivado settings not found: $VIVADO_SETTINGS"
  [[ -d "$FIRESIM_XILINX_BOARD_REPO_PATHS" ]] || die "Xilinx board repo not found: $FIRESIM_XILINX_BOARD_REPO_PATHS"
  [[ -f "$FS/sourceme-manager.sh" ]] || die "FireSim sourceme-manager.sh not found: $FS/sourceme-manager.sh"

  export FIRESIM_XILINX_BOARD_REPO_PATHS
  # shellcheck disable=SC1090
  source "$VIVADO_SETTINGS"
  ensure_firesim_env
  pushd "$FS" >/dev/null
  # shellcheck disable=SC1091
  source ./sourceme-manager.sh --skip-ssh-setup
  popd >/dev/null
}

prepare_configs

if [[ "$REUSE_EXISTING" -eq 1 ]]; then
  latest=$(find_latest_toy_tar) || die "no existing Toy U280 firesim.tar.gz found"
  verify_bitstream_tar "$latest"
  exit 0
fi

enter_nix_if_needed "${ORIGINAL_ARGS[@]}"
source_tool_env

cd "$FS/deploy"
firesim buildbitstream \
  -q \
  -a "$CFG/config_hwdb.yaml" \
  -b "$CFG/config_build.yaml" \
  -r "$CFG/config_build_recipes.yaml" \
  -c "$CFG/config_runtime.yaml"

latest=$(find_latest_toy_tar) || die "build finished, but no Toy U280 firesim.tar.gz was found"
verify_bitstream_tar "$latest"
