# NoHello LKM Demo

NoHello is a small Android arm64 / GKI external kernel module demo. It hides
one configured file path from common filesystem operations by resolving the
target inode at load time and installing kretprobes around VFS-related paths.

This repository is intended for controlled lab/demo use on your own device or
another device where you have explicit permission.

## What It Builds

- `kernel/nohello.c`: kernel module source.
- `kernel/Kbuild`: declares the external module target.
- `kernel/Makefile`: invokes the Android/GKI kernel build tree.
- `ksu-module/`: a minimal KernelSU module wrapper that loads `nohello.ko`.
- `tools/package_ksu.ps1` and `tools/package_ksu.sh`: package helpers.
- `.github/workflows/`: GitHub Actions builds for multiple Android KMI targets.

The default demo target is:

```text
/data/local/tmp/nohello
```

You can override it at load time:

```sh
insmod /data/local/tmp/nohello.ko target_path=/data/local/tmp/nohello
```

Directory listing filtering can be disabled while keeping direct access hidden:

```sh
insmod /data/local/tmp/nohello.ko target_path=/data/local/tmp/nohello hide_dirents=0
```

## Current Status

The project is demo-ready, but it is not a production hardening project.

Implemented:

- Hides direct access through `security_inode_permission`.
- Hides stat/getattr-style checks through `security_inode_getattr`.
- Filters `getdents64` results so the target is removed from directory lists.
- Provides a KernelSU wrapper template for boot-time loading.
- Provides a `hide_dirents` fallback parameter. Set it to `0` if directory
  enumeration is unstable on a device.

Known limitations:

- The target path must exist before `insmod`, because the module stores its
  `(dev, inode)` identity at load time.
- Directory-list filtering compares `d_ino`, because `getdents64` does not
  expose the device id in each returned entry. A same-inode file on another
  filesystem could be hidden from a listing, though direct access checks still
  use both dev and inode.
- Existing open file descriptors are not hidden retroactively.
- The module must match the device KMI/kernel version and arm64 ABI.
- Directory-list filtering is the riskiest part of this demo because it edits
  the `getdents64` user buffer after the syscall returns. If `ls` appears to
  hang, unload the module and retry with `hide_dirents=0`.

## Build

### GitHub Actions

Push to `main` or run the `Build LKM for All KMI Targets` workflow manually.
Artifacts are named like:

```text
android15-6.6_nohello.ko
```

Pick the artifact that matches your device KMI.

### Local DDK/Kernel Build

If your DDK container exports `KDIR`, run:

```sh
cd kernel
CONFIG_KSU=m CC=clang make
```

If you have a kernel build directory locally, pass it explicitly:

```sh
cd kernel
make KDIR=/path/to/kernel/build
```

The output is:

```text
kernel/nohello.ko
```

## Manual Test

On the device:

```sh
adb shell
su
echo "demo secret" > /data/local/tmp/nohello
ls -l /data/local/tmp/nohello
cat /data/local/tmp/nohello
```

Push and load the module:

```sh
adb push kernel/nohello.ko /data/local/tmp/nohello.ko
adb shell
su
insmod /data/local/tmp/nohello.ko target_path=/data/local/tmp/nohello
dmesg | grep nohello
```

Verify:

```sh
ls -l /data/local/tmp/nohello
cat /data/local/tmp/nohello
stat /data/local/tmp/nohello
ls -la /data/local/tmp
```

Unload:

```sh
rmmod nohello
```

## KernelSU Package

`nohello.ko` is not installed directly in KernelSU. KernelSU installs a module
zip, and that zip contains `nohello.ko` plus a `service.sh` script that calls
`insmod`.

Windows PowerShell:

```powershell
.\tools\package_ksu.ps1 -KoPath .\kernel\nohello.ko -Output .\out\nohello-ksu.zip -TargetPath /data/local/tmp/nohello
```

Use `-HideDirents 0` if you want direct-access hiding only.

Linux/macOS shell:

```sh
TARGET_PATH=/data/local/tmp/nohello ./tools/package_ksu.sh kernel/nohello.ko out/nohello-ksu.zip
```

Use `HIDE_DIRENTS=0` if you want direct-access hiding only.

Install `out/nohello-ksu.zip` in KernelSU Manager, reboot, then check:

```sh
su
dmesg | grep nohello
```

To package a safer direct-access-only build:

```powershell
.\tools\package_ksu.ps1 -KoPath .\kernel\nohello.ko -Output .\out\nohello-ksu-direct.zip -TargetPath /data/local/tmp/nohello -HideDirents 0
```

You can also change it on the device after installation:

```sh
su
echo 0 > /data/adb/modules/nohello-demo/hide_dirents.conf
reboot
```

## Use Your Own Module

Replace `kernel/nohello.c` with your module source and update `kernel/Kbuild`.
For a single source file:

```makefile
obj-m += mymod.o
```

For multiple source files:

```makefile
obj-m += mymod.o
mymod-y := mymod_main.o mymod_hook.o mymod_util.o
```

Then update the KernelSU template and package scripts if your output module is
not named `nohello.ko`.
