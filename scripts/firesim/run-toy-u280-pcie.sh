#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: run-toy-u280-pcie.sh [options]

Program/run the BuckyBall Toy U280 FireSim design through the local PCIe flow.
By default this runs: enumeratefpgas -> infrasetup -> runworkload.

Options:
  --bitstream-tar PATH  Use this firesim.tar.gz. Default: newest Toy U280 build result.
  --cfg DIR             Directory for generated FireSim YAML configs.
                        Default: /tmp/buckyball-firesim-toy-u280-$USER
  --no-enumerate        Skip firesim enumeratefpgas.
  --no-infrasetup       Skip firesim infrasetup.
  --infrasetup-only     Stop after enumeratefpgas/infrasetup; do not run workload.
  --kernel-model MODEL  Use bb-tests/output/kernel/fw_payload-<MODEL>.bin as the
                        FireSim boot binary. For Qwen, use: --kernel-model qwen3.
  --kernel-bin PATH     Use an explicit fw_payload*.bin as the FireSim boot binary.
  --build-kernel-model  Build the selected model workload and kernel before launch.
                        For this Toy script the default hart counts are 1 visible/1 total.
                        The workload build uses --chip toy.
  --kernel-visible-harts N
                        Visible hart count used with --build-kernel-model. Default: 1.
  --kernel-total-harts N
                        Total hart count used with --build-kernel-model. Default: visible.
  -h, --help            Show this help.

Environment overrides:
  VIVADO_SETTINGS                     Default: /nfs/tools/xilinx/2022.1/Vivado/2022.1/settings64.sh
  FIRESIM_XILINX_BOARD_REPO_PATHS     Default: $HOME/.cache/xilinx-board-files/open-nic-shell/board_files/Xilinx
  FIRESIM_FPGA_DB                     Default: <FireSim deploy>/firesim-db.json
  BUCKYBALL_FIRESIM_SSH_ADD=1         Optionally run ssh-agent/ssh-add ~/.ssh/firesim.pem.
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
BITSTREAM_TAR=""
DO_ENUMERATE=1
DO_INFRASETUP=1
DO_RUNWORKLOAD=1
KERNEL_MODEL=""
KERNEL_BIN=""
BUILD_KERNEL_MODEL=0
KERNEL_VISIBLE_HARTS=1
KERNEL_TOTAL_HARTS=""
ORIGINAL_ARGS=("$@")

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bitstream-tar)
      [[ $# -ge 2 ]] || die "--bitstream-tar requires a path"
      BITSTREAM_TAR="$2"
      shift
      ;;
    --cfg)
      [[ $# -ge 2 ]] || die "--cfg requires a directory"
      CFG="$2"
      shift
      ;;
    --no-enumerate)
      DO_ENUMERATE=0
      ;;
    --no-infrasetup)
      DO_INFRASETUP=0
      ;;
    --infrasetup-only)
      DO_RUNWORKLOAD=0
      ;;
    --kernel-model)
      [[ $# -ge 2 ]] || die "--kernel-model requires a model name"
      KERNEL_MODEL="${2,,}"
      shift
      ;;
    --kernel-bin)
      [[ $# -ge 2 ]] || die "--kernel-bin requires a path"
      KERNEL_BIN="$2"
      shift
      ;;
    --build-kernel-model)
      BUILD_KERNEL_MODEL=1
      ;;
    --kernel-visible-harts)
      [[ $# -ge 2 ]] || die "--kernel-visible-harts requires a number"
      KERNEL_VISIBLE_HARTS="$2"
      shift
      ;;
    --kernel-total-harts)
      [[ $# -ge 2 ]] || die "--kernel-total-harts requires a number"
      KERNEL_TOTAL_HARTS="$2"
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

KERNEL_TOTAL_HARTS="${KERNEL_TOTAL_HARTS:-$KERNEL_VISIBLE_HARTS}"
if [[ -n "$KERNEL_MODEL" && ! "$KERNEL_MODEL" =~ ^[a-z0-9_.-]+$ ]]; then
  die "invalid kernel model: $KERNEL_MODEL"
fi
if [[ "$BUILD_KERNEL_MODEL" -eq 1 && -z "$KERNEL_MODEL" ]]; then
  die "--build-kernel-model requires --kernel-model MODEL"
fi

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
  [[ -n "$BITSTREAM_TAR" ]] || die "internal error: BITSTREAM_TAR is empty"

  mkdir -p "$CFG"
  cp "$YAML_SRC"/config_*.yaml "$CFG"/

  export BB FS CFG MAKEFRAG FPGA_DB BITSTREAM_TAR KERNEL_MODEL KERNEL_BIN
  python3 - <<'PY'
from pathlib import Path
import os
import re
import json
import shutil

bb = os.environ["BB"]
fs = os.environ["FS"]
cfg = Path(os.environ["CFG"])
makefrag = os.environ["MAKEFRAG"]
fpga_db = os.environ["FPGA_DB"]
kernel_model = os.environ.get("KERNEL_MODEL", "")
kernel_bin = os.environ.get("KERNEL_BIN", "")
raw_tar = os.environ["BITSTREAM_TAR"]
if raw_tar.startswith("file://"):
    bitstream_uri = raw_tar
else:
    bitstream_uri = "file://" + str(Path(raw_tar).resolve())

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
if kernel_bin:
    kernel_path = Path(kernel_bin).resolve()
    if not kernel_path.is_file():
        raise FileNotFoundError(f"kernel boot binary not found: {kernel_path}")
    suffix = kernel_model if kernel_model else re.sub(r"[^A-Za-z0-9_.-]+", "-", kernel_path.stem)
    workload_name = f"buckyball-{suffix}"
    workload_dir = Path(fs) / "deploy" / "workloads" / workload_name
    workload_dir.mkdir(parents=True, exist_ok=True)

    staged_kernel = workload_dir / kernel_path.name
    if staged_kernel.exists() or staged_kernel.is_symlink():
        staged_kernel.unlink()
    try:
        staged_kernel.symlink_to(kernel_path)
    except OSError:
        shutil.copy2(kernel_path, staged_kernel)

    workload_json = Path(fs) / "deploy" / "workloads" / f"{workload_name}.json"
    workload_json.write_text(json.dumps({
        "benchmark_name": workload_name,
        "common_bootbinary": kernel_path.name,
        "common_rootfs": None,
        "common_outputs": [],
        "common_simulation_outputs": [
            "uartlog",
            "memory_stats*.csv"
        ]
    }, indent=2) + "\n")
    text = re.sub(r"workload_name:\s*.*",
                  f"workload_name: {workload_name}.json",
                  text)
runtime.write_text(text)

hwdb = cfg / "config_hwdb.yaml"
text = hwdb.read_text()
text = re.sub(
    r"(?ms)^alveo_u280_firesim_BuckyballToyConfig_no_nic:\n(?:^[ \t].*\n)*",
    "",
    text,
)
text = text.rstrip() + "\n\n" + (
    "alveo_u280_firesim_BuckyballToyConfig_no_nic:\n"
    f"    bitstream_tar: {bitstream_uri}\n"
    "    deploy_quintuplet_override: null\n"
    "    custom_runtime_config: null\n"
)
hwdb.write_text(text)
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

build_kernel_model_if_requested() {
  [[ "$BUILD_KERNEL_MODEL" -eq 1 ]] || return 0
  command -v bbdev >/dev/null 2>&1 || die "bbdev is not in PATH; source the BuckyBall/nix environment first"

  local kernel_args
  kernel_args="--visible-hart-count $KERNEL_VISIBLE_HARTS --total-hart-count $KERNEL_TOTAL_HARTS --model $KERNEL_MODEL"

  cd "$BB"
  bbdev workload --build "--chip toy --model $KERNEL_MODEL"
  bbdev kernel --build "$kernel_args"
}

resolve_kernel_bin() {
  [[ -n "$KERNEL_MODEL" || -n "$KERNEL_BIN" ]] || return 0

  if [[ -n "$KERNEL_BIN" ]]; then
    [[ -f "$KERNEL_BIN" ]] || die "kernel boot binary not found: $KERNEL_BIN"
    KERNEL_BIN=$(realpath "$KERNEL_BIN")
    return 0
  fi

  local output_dir="$BB/bb-tests/output/kernel"
  local harted="$output_dir/fw_payload-v${KERNEL_VISIBLE_HARTS}-t${KERNEL_TOTAL_HARTS}-${KERNEL_MODEL}.bin"
  local default="$output_dir/fw_payload-${KERNEL_MODEL}.bin"

  if [[ -f "$harted" ]]; then
    KERNEL_BIN="$harted"
  elif [[ -f "$default" ]]; then
    KERNEL_BIN="$default"
  else
    die "kernel boot binary for model '$KERNEL_MODEL' was not found.
Expected one of:
  $harted
  $default
Build it with:
  bbdev workload --build '--chip toy --model $KERNEL_MODEL'
  bbdev kernel --build '--visible-hart-count $KERNEL_VISIBLE_HARTS --total-hart-count $KERNEL_TOTAL_HARTS --model $KERNEL_MODEL'
or rerun this script with --build-kernel-model."
  fi

  KERNEL_BIN=$(realpath "$KERNEL_BIN")
}

setup_ssh_agent_if_requested() {
  [[ "${BUCKYBALL_FIRESIM_SSH_ADD:-0}" == "1" ]] || return 0
  [[ -t 0 ]] || die "BUCKYBALL_FIRESIM_SSH_ADD=1 requires an interactive terminal"

  local key="$HOME/.ssh/firesim.pem"
  [[ -f "$key" ]] || return 0

  if [[ -z "${SSH_AUTH_SOCK:-}" ]]; then
    eval "$(ssh-agent -s)" >/dev/null
  fi

  ssh-add -l >/dev/null 2>&1 || ssh-add "$key"
}

if [[ -z "$BITSTREAM_TAR" ]]; then
  BITSTREAM_TAR=$(find_latest_toy_tar) || die "no Toy U280 firesim.tar.gz found; run build-toy-u280-bitstream.sh first"
fi

verify_bitstream_tar "$BITSTREAM_TAR"
enter_nix_if_needed "${ORIGINAL_ARGS[@]}"
source_tool_env
build_kernel_model_if_requested
resolve_kernel_bin
prepare_configs
setup_ssh_agent_if_requested

cd "$FS/deploy"
common_args=(
  -a "$CFG/config_hwdb.yaml"
  -b "$CFG/config_build.yaml"
  -r "$CFG/config_build_recipes.yaml"
  -c "$CFG/config_runtime.yaml"
)

echo "Using Toy U280 bitstream:"
echo "  $BITSTREAM_TAR"
echo "Using generated FireSim configs:"
echo "  $CFG"
if [[ -n "$KERNEL_BIN" ]]; then
  echo "Using FireSim boot binary:"
  echo "  $KERNEL_BIN"
fi

if [[ "$DO_ENUMERATE" -eq 1 ]]; then
  firesim enumeratefpgas "${common_args[@]}"
fi

if [[ "$DO_INFRASETUP" -eq 1 ]]; then
  firesim infrasetup "${common_args[@]}"
fi

if [[ "$DO_RUNWORKLOAD" -eq 1 ]]; then
  firesim runworkload "${common_args[@]}"
fi
