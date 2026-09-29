#!/usr/bin/env bash
#
# Boot rCore-Tutorial-v3 on RustSBI Prototyper in QEMU, either from the dynamic
# firmware (`$0 sbi`, the default) or through U-Boot on the jump firmware
# (`$0 u-boot`), which starts the kernel with `booti`.
#
# Payload and U-Boot are pinned revisions whose build products are cached;
# RustSBI is rebuilt every run and is not.

set -euo pipefail

if (( $# > 1 )); then
  echo "Usage: $0 [sbi|u-boot]" >&2
  exit 2
fi

readonly BOOT_MODE="${1:-sbi}"
case "$BOOT_MODE" in
  sbi | u-boot) ;;
  *)
    echo "Unknown boot path: ${BOOT_MODE}" >&2
    echo "Usage: $0 [sbi|u-boot]" >&2
    exit 2
    ;;
esac

readonly RCORE_REPO="https://github.com/rcore-os/rCore-Tutorial-v3"
readonly RCORE_REV="c91bd3752b53ff48555aef4e3c7b8d5ddc8ee6e1"
readonly UBOOT_REPO="https://github.com/u-boot/u-boot"
readonly UBOOT_REV="25049ad560826f7dc1c4740883b0016014a59789"
readonly CROSS_COMPILE="riscv64-linux-gnu-"

# U-Boot is loaded where the kernel is linked to run; `booti` reads the payload
# from UBOOT_PAYLOAD_ADDR.
readonly UBOOT_PAYLOAD_ADDR="0x84000000"
readonly UBOOT_LOAD_ADDR="0x80200000"

# rCore-Tutorial prints these on successful boot.
readonly DTREE_MARKER="CLOCK_FREQ from device tree"
readonly SHELL_MARKER="Rust user shell"

readonly CACHE_DIR="${RCORE_CACHE_DIR:-.cache/rcore-tutorial}"
readonly UBOOT_CACHE_DIR="${UBOOT_CACHE_DIR:-.cache/uboot-smode}"
# Kept outside the repository: a payload cloned below its root sits in a cargo
# workspace it is not a member of, and cargo refuses to build it.
readonly WORK_DIR="${RCORE_WORK_DIR:-${RUNNER_TEMP:-/tmp}/rcore-tutorial/work}"
readonly LOG_DIR="${QEMU_LOG_DIR:-qemu-logs}"
readonly LOG_FILE="${LOG_DIR}/prototyper-rcore-tutorial-${BOOT_MODE}.log"
readonly BOOT_TIMEOUT_SECS=120

readonly RCORE_TREE="${WORK_DIR}/rCore-Tutorial-v3"
readonly RCORE_ELF="${RCORE_TREE}/os/target/riscv64gc-unknown-none-elf/release/os"
readonly RCORE_BIN="${CACHE_DIR}/os.bin"
readonly RCORE_IMAGE="${CACHE_DIR}/os.img"
readonly RCORE_FS="${RCORE_TREE}/user/target/riscv64gc-unknown-none-elf/release/fs.img"

readonly UB_TREE="${WORK_DIR}/u-boot"
readonly UB_BIN="${UBOOT_CACHE_DIR}/u-boot.bin"

case "$BOOT_MODE" in
  sbi)    readonly RUSTSBI="${CARGO_TARGET_DIR:-target}/riscv64gc-unknown-none-elf/release/rustsbi-prototyper-dynamic.elf" ;;
  u-boot) readonly RUSTSBI="${CARGO_TARGET_DIR:-target}/riscv64gc-unknown-none-elf/release/rustsbi-prototyper-jump.elf" ;;
esac

QEMU_PID=""
BOOT_FAILURE_PATTERN=""
case "$BOOT_MODE" in
  sbi)    BOOT_FAILURE_PATTERN="" ;;
  u-boot) BOOT_FAILURE_PATTERN="Bad Linux RISCV Image magic" ;;
esac

clone_pinned() { # $1=repo $2=rev $3=tree
  if [[ -d "$3/.git" ]]; then
    local head
    head="$(git -C "$3" rev-parse HEAD 2>/dev/null || echo '')"
    if [[ "$head" == "$2" ]]; then
      echo "Using cached $(basename "$3") at ${2:0:12}" >&2
      return
    fi
  fi

  rm -rf "$3"
  mkdir -p "$3"
  git -C "$3" init -q
  git -C "$3" remote add origin "$1"
  git -C "$3" fetch -q --depth 1 origin "$2"
  git -C "$3" checkout -q FETCH_HEAD
  echo "Cloned $(basename "$3") at ${2:0:12}" >&2
}

build_rcore() {
  if [[ -s "$RCORE_BIN" ]]; then
    echo "Using cached rCore-Tutorial binary" >&2
    return
  fi

  clone_pinned "$RCORE_REPO" "$RCORE_REV" "$RCORE_TREE"
  
  echo "Building rCore-Tutorial..." >&2
  make -C "${RCORE_TREE}/os" build >/dev/null 2>&1
  test -s "$RCORE_ELF"

  mkdir -p "$CACHE_DIR"
  riscv64-linux-gnu-objcopy -O binary "$RCORE_ELF" "$RCORE_BIN"
  echo "Built rCore-Tutorial ($(stat -c%s "$RCORE_BIN") bytes)" >&2
}

build_uboot() {
  if [[ -s "$UB_BIN" ]]; then
    echo "Using cached U-Boot binary" >&2
    return
  fi

  clone_pinned "$UBOOT_REPO" "$UBOOT_REV" "$UB_TREE"

  echo "Building U-Boot..." >&2
  make -C "$UB_TREE" qemu-riscv64_smode_defconfig CROSS_COMPILE="$CROSS_COMPILE" >/dev/null 2>&1
  "${UB_TREE}/scripts/config" --file "${UB_TREE}/.config" \
    --enable CONFIG_USE_BOOTCOMMAND \
    --set-str CONFIG_BOOTCOMMAND "booti ${UBOOT_PAYLOAD_ADDR} - \${fdtcontroladdr}"
  make -C "$UB_TREE" -j"$(nproc)" CROSS_COMPILE="$CROSS_COMPILE" >/dev/null 2>&1

  mkdir -p "$UBOOT_CACHE_DIR"
  cp "${UB_TREE}/u-boot.bin" "$UB_BIN"
  echo "Built U-Boot ($(stat -c%s "$UB_BIN") bytes)" >&2
}

# `booti` needs the 64-byte RISC-V Linux Image header, whose text_offset puts
# the payload at 0x841fffc0 and whose code0 jumps the 64 bytes to 0x84000000.
build_image_header() { # $1=raw kernel binary $2=wrapped image
  mkdir -p "$(dirname "$2")"

  python3 - "$1" "$2" <<'PY'
import struct
import sys

TEXT_OFFSET = 0x1FFFC0
JAL_X0_64 = 0x0400006F
MAGIC = 0x05435352

raw = open(sys.argv[1], "rb").read()
header = struct.pack(
    "<IIQQQIIQQII",
    JAL_X0_64, 0,                # code0, code1
    TEXT_OFFSET, len(raw) + 64,  # text_offset, image_size
    0,                           # flags
    2, 0,                        # version, res1
    0,                           # res2
    0x0000005643534952,          # res3: "RISCV\0\0\0"
    MAGIC, 0,                    # magic, res4
)
assert len(header) == 64, len(header)
open(sys.argv[2], "wb").write(header + raw)
PY
}

check_prerequisites() {
  test -s "$RUSTSBI" || {
    echo "Missing $RUSTSBI; run 'cargo prototyper build' first" >&2
    return 1
  }
  qemu-system-riscv64 --version
}

stop_qemu() {
  if [[ -n "$QEMU_PID" ]] && kill -0 "$QEMU_PID" 2>/dev/null; then
    kill "$QEMU_PID" 2>/dev/null || true
    wait "$QEMU_PID" 2>/dev/null || true
  fi
}

boot_sbi() {
  mkdir -p "$LOG_DIR"
  : >"$LOG_FILE"

  echo "Booting via RustSBI (dynamic mode)..." >&2
  qemu-system-riscv64 \
    -machine virt \
    -smp 1 \
    -m 128M \
    -nographic \
    -no-reboot \
    -bios "$RUSTSBI" \
    -kernel "$RCORE_ELF" \
    -drive "file=${RCORE_FS},if=none,format=raw,id=x0" \
    -device virtio-blk-device,drive=x0 \
    -device virtio-gpu-device \
    -device virtio-keyboard-device \
    -device virtio-mouse-device \
    >"$LOG_FILE" 2>&1 &
  QEMU_PID=$!
}

boot_uboot() {
  mkdir -p "$LOG_DIR"
  : >"$LOG_FILE"

  echo "Booting via U-Boot..." >&2
  qemu-system-riscv64 \
    -machine virt \
    -smp 1 \
    -m 128M \
    -nographic \
    -no-reboot \
    -bios "$RUSTSBI" \
    -device "loader,file=${UB_BIN},addr=${UBOOT_LOAD_ADDR}" \
    -device "loader,file=${RCORE_IMAGE},addr=${UBOOT_PAYLOAD_ADDR}" \
    -drive "file=${RCORE_FS},if=none,format=raw,id=x0" \
    -device virtio-blk-device,drive=x0 \
    -device virtio-gpu-device \
    -device virtio-keyboard-device \
    -device virtio-mouse-device \
    >"$LOG_FILE" 2>&1 &
  QEMU_PID=$!
}

# The kernel writes NUL bytes into the log, so grep needs -a to print matches.
kernel_is_ready() {
  grep -Faq "$DTREE_MARKER" "$LOG_FILE" && grep -Faq "$SHELL_MARKER" "$LOG_FILE"
}

boot_has_failed() {
  [[ -n "$BOOT_FAILURE_PATTERN" ]] || return 1
  grep -Eaq "$BOOT_FAILURE_PATTERN" "$LOG_FILE"
}

report_boot_failure() {
  echo "rCore-Tutorial failed to boot:" >&2
  grep -Ea --max-count=5 "$BOOT_FAILURE_PATTERN" "$LOG_FILE" >&2 || true
  tail -n 120 "$LOG_FILE" >&2 || true
}

report_early_exit() {
  local qemu_exit
  set +e
  wait "$QEMU_PID"
  qemu_exit=$?
  set -e

  echo "QEMU exited before rCore-Tutorial reached the shell (exit=${qemu_exit})" >&2
  tail -n 120 "$LOG_FILE" >&2 || true
}

wait_for_boot() {
  local elapsed=0
  while (( elapsed < BOOT_TIMEOUT_SECS )); do
    if ! kill -0 "$QEMU_PID" 2>/dev/null; then
      report_early_exit
      return 1
    fi

    if kernel_is_ready; then
      stop_qemu
      return 0
    fi

    if boot_has_failed; then
      stop_qemu
      report_boot_failure
      return 1
    fi

    sleep 1
    : $(( elapsed++ ))
  done

  echo "Boot timed out after ${BOOT_TIMEOUT_SECS}s" >&2
  stop_qemu
  tail -n 120 "$LOG_FILE" >&2 || true
  return 1
}

main() {
  trap stop_qemu EXIT

  check_prerequisites
  build_rcore

  case "$BOOT_MODE" in
    sbi)
      boot_sbi
      ;;
    u-boot)
      build_uboot
      build_image_header "$RCORE_BIN" "$RCORE_IMAGE"
      boot_uboot
      ;;
  esac

  if wait_for_boot; then
    echo "rCore-Tutorial booted successfully via ${BOOT_MODE}" >&2
    return 0
  else
    echo "rCore-Tutorial boot failed via ${BOOT_MODE}" >&2
    return 1
  fi
}

main "$@"
