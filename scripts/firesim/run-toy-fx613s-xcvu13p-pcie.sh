#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: run-toy-fx613s-xcvu13p-pcie.sh [options]

Prepare/run the BuckyBall Toy FX613S XCVU13P FireSim design through the local
PCIe flow. By default this keeps the U280 script shape:
enumeratefpgas -> infrasetup -> runworkload.

Options:
  --dry-run            Generate/check configs and print the FireSim commands,
                       but do not invoke firesim or touch hardware.
  --bitstream-tar PATH Use this firesim.tar.gz. Default: newest Toy FX613S build result.
  --cfg DIR            Directory for generated FireSim YAML configs.
                       Default: /tmp/buckyball-firesim-toy-fx613s-xcvu13p-$USER
  --no-enumerate       Skip firesim enumeratefpgas.
  --no-infrasetup      Skip firesim infrasetup.
  --infrasetup-only    Stop after enumeratefpgas/infrasetup; do not run workload.
  -h, --help           Show this help.

Environment overrides:
  VIVADO_SETTINGS Default: /nfs/tools/xilinx/2022.1/Vivado/2022.1/settings64.sh
  FIRESIM_FPGA_DB Default: <FireSim deploy>/firesim-db.json
EOF
}

die() {
  echo "error: $*" >&2
  exit 1
}

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
SCRIPT_PATH="$SCRIPT_DIR/$(basename -- "${BASH_SOURCE[0]}")"
BB=$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)
FS="$BB/arch/thirdparty/chipyard/sims/firesim"
YAML_SRC="$BB/bbdev/api/steps/firesim/scripts/yaml"
MAKEFRAG="$BB/bbdev/api/steps/firesim/scripts/makefrag/firesim"
CFG="${BUCKYBALL_FIRESIM_CFG:-/tmp/buckyball-firesim-toy-fx613s-xcvu13p-${USER:-user}}"
BITSTREAM_TAR=""
DRY_RUN=0
DO_ENUMERATE=1
DO_INFRASETUP=1
DO_RUNWORKLOAD=1
ORIGINAL_ARGS=("$@")

FX_PLATFORM="fx613s_xcvu13p"
FX_BUILD_KEY="fx613s_xcvu13p_firesim_BuckyballToyConfig_no_nic"
FX_DEPLOY_MANAGER="FX613sXcvu13pInstanceDeployManager"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=1
      ;;
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
FPGA_DB="${FIRESIM_FPGA_DB:-$FS/deploy/firesim-db.json}"

find_latest_toy_tar() {
  python3 - "$FS" <<'PY'
from pathlib import Path
import sys

root = Path(sys.argv[1]) / "deploy" / "results-build"
matches = list(root.glob("*fx613s_xcvu13p_firesim_BuckyballToyConfig_no_nic*/**/firesim.tar.gz"))
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
  grep -qx "$FX_PLATFORM/firesim.bit" <<<"$contents" || die "firesim.bit missing in $tarball"
  grep -qx "$FX_PLATFORM/firesim.mcs" <<<"$contents" || die "firesim.mcs missing in $tarball"
  grep -qx "$FX_PLATFORM/metadata" <<<"$contents" || die "metadata missing in $tarball"
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

  export BB FS CFG MAKEFRAG FPGA_DB BITSTREAM_TAR FX_BUILD_KEY FX_DEPLOY_MANAGER
  python3 - <<'PY'
from pathlib import Path
import os
import re

bb = os.environ["BB"]
fs = os.environ["FS"]
cfg = Path(os.environ["CFG"])
makefrag = os.environ["MAKEFRAG"]
fpga_db = os.environ["FPGA_DB"]
raw_tar = os.environ["BITSTREAM_TAR"]
fx_build_key = os.environ["FX_BUILD_KEY"]
fx_deploy_manager = os.environ["FX_DEPLOY_MANAGER"]

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
    f"    - {fx_build_key}\n\n",
    text,
    count=1,
)
build.write_text(text)

runtime = cfg / "config_runtime.yaml"
text = runtime.read_text()
text = re.sub(r"default_platform:\s*.*",
              f"default_platform: {fx_deploy_manager}",
              text)
text = re.sub(r"default_simulation_dir:\s*.*",
              f"default_simulation_dir: {fs}/deploy/FIRESIM_RUNS_DIR",
              text)
text = re.sub(r"default_fpga_db:\s*.*",
              f"default_fpga_db: {fpga_db}",
              text)
text = re.sub(r"default_hw_config:\s*.*",
              f"default_hw_config: {fx_build_key}",
              text)
runtime.write_text(text)

hwdb = cfg / "config_hwdb.yaml"
text = hwdb.read_text()
text = re.sub(
    r"(?ms)^fx613s_xcvu13p_firesim_BuckyballToyConfig_no_nic:\n(?:^[ \t].*\n)*",
    "",
    text,
)
text = re.sub(
    r"(?ms)^alveo_u280_firesim_BuckyballToyConfig_no_nic:\n(?:^[ \t].*\n)*",
    "",
    text,
)
text = text.rstrip() + "\n\n" + (
    f"{fx_build_key}:\n"
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
    exec nix develop --command bash "$SCRIPT_PATH" "${ORIGINAL_ARGS[@]}"
  fi
}

source_tool_env() {
  [[ -f "$VIVADO_SETTINGS" ]] || die "Vivado settings not found: $VIVADO_SETTINGS"
  [[ -f "$FS/sourceme-manager.sh" ]] || die "FireSim sourceme-manager.sh not found: $FS/sourceme-manager.sh"

  # shellcheck disable=SC1090
  source "$VIVADO_SETTINGS"
  ensure_firesim_env
  pushd "$FS" >/dev/null
  # shellcheck disable=SC1091
  source ./sourceme-manager.sh --skip-ssh-setup
  popd >/dev/null
}

if [[ -z "$BITSTREAM_TAR" ]]; then
  BITSTREAM_TAR=$(find_latest_toy_tar) || die "no Toy FX613S firesim.tar.gz found; run build-toy-fx613s-xcvu13p-bitstream.sh first"
fi

verify_bitstream_tar "$BITSTREAM_TAR"
prepare_configs

common_args=(
  -a "$CFG/config_hwdb.yaml"
  -b "$CFG/config_build.yaml"
  -r "$CFG/config_build_recipes.yaml"
  -c "$CFG/config_runtime.yaml"
)

echo "Using Toy FX613S XCVU13P bitstream:"
echo "  $BITSTREAM_TAR"
echo "Using generated FireSim configs:"
echo "  $CFG"

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "Dry run only; not invoking firesim or touching hardware."
  echo "Would run from $FS/deploy:"
  if [[ "$DO_ENUMERATE" -eq 1 ]]; then
    printf '  firesim enumeratefpgas'
    printf ' %q' "${common_args[@]}"
    printf '\n'
  fi
  if [[ "$DO_INFRASETUP" -eq 1 ]]; then
    printf '  firesim infrasetup'
    printf ' %q' "${common_args[@]}"
    printf '\n'
  fi
  if [[ "$DO_RUNWORKLOAD" -eq 1 ]]; then
    printf '  firesim runworkload'
    printf ' %q' "${common_args[@]}"
    printf '\n'
  fi
  exit 0
fi

enter_nix_if_needed
source_tool_env

cd "$FS/deploy"

if [[ "$DO_ENUMERATE" -eq 1 ]]; then
  firesim enumeratefpgas "${common_args[@]}"
fi

if [[ "$DO_INFRASETUP" -eq 1 ]]; then
  firesim infrasetup "${common_args[@]}"
fi

if [[ "$DO_RUNWORKLOAD" -eq 1 ]]; then
  firesim runworkload "${common_args[@]}"
fi
