# rCore-Tutorial

[rCore-Tutorial-v3](https://github.com/rcore-os/rCore-Tutorial-v3) is a step-by-step tutorial for building a RISC-V operating system kernel from scratch, designed for teaching OS concepts.

## Boot Paths

The CI tests two boot paths:

### SBI Path (Direct Boot)

```bash
cargo prototyper build
qemu-system-riscv64 \
  -machine virt -m 128M -nographic \
  -bios rustsbi-prototyper-dynamic.elf \
  -kernel os \
  -drive file=fs.img,if=none,format=raw,id=x0 \
  -device virtio-blk-device,drive=x0 \
  -device virtio-gpu-device \
  -device virtio-keyboard-device \
  -device virtio-mouse-device
```

**Requirements**: Depends on [PR #342](https://github.com/rustsbi/rustsbi/pull/342) for correct DTB placement outside the firmware's `no-map` region.

### U-Boot Path

```bash
cargo prototyper build jump
# Build U-Boot (qemu-riscv64_smode_defconfig)
# Add Linux Image header to kernel binary
qemu-system-riscv64 \
  -machine virt -m 128M -nographic \
  -bios rustsbi-prototyper-jump.elf \
  -device loader,file=u-boot.bin,addr=0x80200000 \
  -device loader,file=os.img,addr=0x84000000 \
  -drive file=fs.img,if=none,format=raw,id=x0 \
  -device virtio-blk-device,drive=x0 \
  -device virtio-gpu-device \
  -device virtio-keyboard-device \
  -device virtio-mouse-device
```

**Requirements**: U-Boot manages its own device tree, bypassing the issue in [#329](https://github.com/rustsbi/rustsbi/issues/329).

## Technical Notes

- rCore-Tutorial requires device tree parsing early in boot
- The U-Boot path adds a 64-byte RISC-V Linux Image header for `booti` compatibility
- Success markers: `CLOCK_FREQ from device tree` and `Rust user shell`

## References

- Repository: <https://github.com/rcore-os/rCore-Tutorial-v3>
- Related Issues: [#329](https://github.com/rustsbi/rustsbi/issues/329)
- Related PRs: [#342](https://github.com/rustsbi/rustsbi/pull/342)
