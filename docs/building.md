# Building LiveExec32

[Back to the README](../README.md) · [Configuration and diagnostics](configuration.md)

Run the commands below from the repository root.

## Host app and prerequisites

Initialize the submodules, then prepare the guest frameworks and root filesystem
below before building the host app with Theos:

```bash
git submodule update --init --recursive
```

The host build configures Dynarmic automatically with CMake and links its
static libraries into `LiveExec32Shared`. This requires CMake and Boost
1.57 or newer on the build machine.

### Complete Linux build

Install Theos with its Linux iPhone toolchain and iPhoneOS 16.5 SDK, Clang,
GNUstep Base development headers and Objective-C runtime, CMake, Boost,
Python 3, `rsync`, `unzip`, and `hfstar` from
[hfsfuse](https://github.com/0x09/hfsfuse). The generator runs as a native
Linux program against GNUstep; the guest frameworks and host app use Theos'
Apple-targeting Clang. An `ios-clang` wrapper configured for arm64 cannot
replace the armv7s guest compiler.

With a local iOS 10.3.3 iPhone 5 IPSW, run the complete packaging sequence:

```bash
export THEOS=/path/to/theos
export RAMDISK_LOCAL_IPSW=/path/to/iPhone_4.0_32bit_10.3.3_14G60_Restore.ipsw
install -Dm755 /path/to/hfstar tmp/tools/hfstar
git submodule update --init --recursive
make -C GuestMakefile generate-shims
make -C GuestMakefile -j4
PATH="$THEOS/toolchain/linux/iphone/bin:$PATH" ./GuestMakefile/pack-ramdisk.sh
make package PACKAGE_FORMAT=deb THEOS_PACKAGE_SCHEME=rootless
make package
```

The packages appear under `packages/`. The generator reads the tracked
Objective-C signatures, including 13 private UIKit classes, from
`Generator/templates/generated.plist`. The matching nightly guest UIKit image
was used to capture those classes' armv7s method encodings. Linux does not
need a running Catalyst UIKit for generation. The `tmp/` directory is an
ignored, disk-backed cache inside the repository; its SDK, IPSW components,
and `tmp/tools/hfstar` survive a reboot.
Linux version stamping uses Python's `plistlib`, so neither Apple's
`plutil -replace` command nor a temporary `plutil` wrapper is required.

## Guest frameworks

Generate the guest Objective-C shims, then build the frameworks:

```bash
gmake -C GuestMakefile generate-shims
gmake -C GuestMakefile
```

With GNU Make 4.3 or newer, independent frameworks and their source files are
built through the shared jobserver; pass `-jN` to cap concurrency. Guest
frameworks also share the SDK's MRC/ARC Clang module contexts, keeping a
cold module cache compact. Set `LC32_SHARE_GUEST_MODULE_CACHE=0` only when
diagnosing an isolated Clang module-cache issue.

### ARM32 linker

ARM32 guest frameworks, tests, and libiconv require a classic linker. macOS
resolves it with `xcrun --find ld-classic`; Linux selects the Apple linker in
`$THEOS/toolchain/linux/iphone/bin/ld`. Newer Xcode linkers can emit
incorrect Thumb initializer pointers, and `-Wl,-ld_classic` no longer
selects the classic linker. If the selected toolchain does not provide it,
choose a toolchain that does or pass
`LC32_GUEST_LINKER=/absolute/path/to/ld-classic` to `gmake` (or in the
environment when running `GuestMakefile/build-libiconv.sh` directly).

With the guest SDK already prepared, check the linker and its ARM32
constructor/function-pointer output without requiring Theos:

```bash
gmake -C test check-guest-thumb-linker
```

### Guest SDK

The guest build downloads the third-party iOS 10.3 SDK archive to
`tmp/iPhoneOS10.3.sdk.tar.gz`, verifies its pinned SHA-256 checksum, and
extracts it atomically to `tmp/iPhoneOS10.3.sdk` for subsequent builds. Set
`ISYSROOT=/path/to/iPhoneOS10.3.sdk` to use an SDK obtained elsewhere, or
override `LC32_GUEST_SDK_URL` and `LC32_GUEST_SDK_SHA256` together when
using another mirror. The archive is hosted by a third party and remains
subject to Apple's SDK terms. Run `gmake -C GuestMakefile sdk` to prefetch
it without building. Theos still needs its separate iPhoneOS 16.5 SDK to
link the project.

### Shim generator checks

The generator reports methods disabled by unsupported type encodings,
separately from intentionally filtered/manual methods. Run
`Generator/GenerateShimAPI/test-object-out-pointers.sh` to check object
output marshalling and the captured-template disabled-method baseline.
Build the corresponding ARM32 runtime regression with
`gmake -C test object-out-parameters`.

Run `sh Generator/GenerateShimAPI/test-coremedia-time.sh` to check generated
by-value `CMTime` arguments and returns, including the video writer's pixel
buffer argument. Build the native API round-trip regression with
`gmake -C test coremedia-time-bridge`. Its runtime assertions require
LiveExec32 on iOS; a Linux build verifies compilation and linking only.

See [Objective-C proxy bridge](ObjCProxy.md) for the bridge design and
marshalling contracts.

### libiconv

The same build also downloads and verifies Apple's `libiconv-50` source at
commit `6bcfda8c4720659e855c04ce72a8335fb4a67b0b`, then builds the armv7s
`/usr/lib/libiconv.2.dylib` used by older apps. The source and archive are
cached under `tmp/`; run `gmake -C GuestMakefile libiconv` to build only
that library. This library remains covered by the LGPL license shipped in
Apple's source archive; the guest root includes that license at
`/usr/local/OpenSourceLicenses/libiconv.txt`.

## Guest root filesystem

Set up the guest root filesystem and install the built shim frameworks:

```bash
./GuestMakefile/pack-ramdisk.sh
```

On the first run this downloads the iOS 10.3.3 restore ramdisk component
(`058-75249-062.dmg`) from Apple's IPSW, verifies its pinned checksum,
extracts its Img3 payload, and copies it into `Resources/RootFS` with
`rsync -aH` (7z would break the HFS symlinks and dylib hardlink pairs that
the guest dyld relies on). The download and extracted image are cached
under `tmp/ipsw/`, so subsequent runs only reinstall the rebuilt
frameworks.

Set `RAMDISK_LOCAL_IPSW` to extract the component from an existing IPSW with
`unzip`. Linux uses `hfstar` and GNU tar to read the decrypted HFS+ image.
The script first checks `tmp/tools/hfstar`, then `PATH`; set `HFSTAR` to an
explicit executable path to override either choice. macOS uses
`hdiutil`. Override the sources with `RAMDISK_IPSW_URL`, `RAMDISK_IPSW_COMPONENT`,
`RAMDISK_IPSW_COMPONENT_SHA256`, `RAMDISK_IMAGE_SHA256`,
`RAMDISK_SETUP_DIR`, and `RAMDISK_ROOT`. Framework bundle metadata is
tracked under `GuestMakefile/FrameworkInfoPlists`; override that snapshot
with `FRAMEWORK_INFO_ROOT`, or set `IOS_SYSTEM_ROOT` to test against another
mounted system image. The remote download path requires `pzb`; all paths
require Python 3 and `rsync`.

## Assemble the host app

After packing the guest root filesystem, build the host app so it embeds the
updated resources:

```bash
gmake
```

For local execution tests on macOS, use `gmake LC32_BUILD_CATALYST=1` instead.
This opt-in mode rewrites and re-signs only the assembled app and its embedded
frameworks for Catalyst; a subsequent plain `gmake` restores normal iOS
artifacts without requiring `clean`.

## Launching a binary

On an iOS device, pass the ARM32 executable path to the installed launcher:

```bash
/path/to/LiveExec32.app/LiveExec32 /var/mobile/ramdisk32/usr/bin/fdisk
```

See [guest environment](configuration.md#guest-environment) for forwarding
environment variables and enabling guest dyld diagnostics.

The default build targets iOS and cannot run directly on macOS; use the
Catalyst build mode above for local execution tests.

## Release version and build metadata

`Version:` in the root `control` file is the single release-version source
(use a numeric version such as `0.0.1`). Builds copy it into
`CFBundleShortVersionString` for LiveExec32, LiveExec32Shared, and LC32HelpUI
before signing; tracked Info.plist templates are not rewritten. Theos can
still append package-only suffixes via `PACKAGE_BUILDNAME` or `PACKAGE_VERSION`.
`CFBundleVersion` remains each bundle's separate build number.
Startup logs include that release version, the 7-character Git commit
(with `-dirty` for tracked local changes), branch, device model, and OS.
Detached CI checkouts use `GITHUB_HEAD_REF`/`GITHUB_REF_NAME` for the branch;
source archives without Git metadata use `unknown` for the commit.
Run `gmake -C test check-build-info` for the metadata/logging regressions.
