# Valence: plan and roadmap

Valence is an x86_64 Linux distribution built from scratch, in the old style: an LTS kernel, BSD-style init
scripts you can read top to bottom, plain tarball packages, and a text-mode installer. It also ships a modern
desktop (KDE Plasma) and a Btrfs root that takes a snapshot before every upgrade.

Status, 18 November 2026: the name and the logo are chosen and this plan is written. The first piece, a kernel and
busybox system that boots to a login prompt in QEMU, is written but has not been built yet.

## The rule

> Simple enough to understand in an afternoon. Nothing hidden, nothing clever.

Every part of the boot is a shell script in `/etc/rc.d`. A package is a tarball plus a list of the files it
installed. If something breaks, you should be able to fix it with `vi` and a root shell.

## The stack

| | |
|---|---|
| Kernel | Linux LTS (6.18 today), built from `x86_64_defconfig` plus a small fragment; moves to the next LTS when it is out |
| Init | BSD-style: `init` reads `/etc/inittab` and runs `rc.S` (boot), `rc.M` (multiuser), `rc.6` (halt/reboot) and `rc.local` |
| libc | glibc |
| Toolchain | A cross toolchain built from source (binutils, GCC, glibc), then the system rebuilds itself |
| Core tools | BusyBox to start; see "Not decided yet" |
| Packages | Tarballs (`.txz`) with `installpkg`, `removepkg` and `upgradepkg`, which are shell scripts, and `pkg` on top: it fetches packages over the web and resolves dependencies. What is installed is recorded in `/var/log/packages`. Each package is built by a plain shell build script. See "Packages" below |
| Docs | Man pages and docs are shipped, not stripped |
| Filesystem | Btrfs root with subvolumes; `upgradepkg` takes a snapshot first, so a bad upgrade is a rollback |
| Boot | GRUB; one ISO and one install that boot on both BIOS and UEFI |
| Installer | `setup`, a text-mode shell script |
| Desktop | KDE Plasma 6 on Wayland, with SDDM |
| Releases | Work lands on `testing`; `main` is what releases are cut from |

## Repository layout

```
Makefile                build everything: kernel, busybox, initramfs; `make run` boots it in QEMU
shell.nix               build dependencies for Nix users (any distro with gcc, make, flex, bison, bc,
                        static glibc and qemu works too)
config/kernel.fragment  kernel options merged over x86_64_defconfig
config/initramfs.list   device nodes added to the initramfs (so building needs no root)
rootfs/                 the root filesystem skeleton: /etc, the rc scripts, inittab
test/boot-test          boots the image in QEMU and checks Phase 1's "done when" (`make test`)
```

**`rootfs/` is a git submodule:** [melon-77/ballpit](https://github.com/melon-77/ballpit). The Makefile copies it
over the busybox install. Clone with:

    git clone --recurse-submodules -b testing git@github.com:melon-77/valence.git

or, in an existing clone, `git submodule update --init`.

## Building

    nix-shell        # or install the tools listed above
    make             # -> out/bzImage, out/initramfs.cpio.gz
    make run         # boot in QEMU on the serial console (Ctrl-a x quits); log in as root, no password
    make test        # boot it, log in, check rc.S/rc.M/DHCP, power off; prints PASS/FAIL per check

## Roadmap

There are no dates. A phase is finished when its "done when" is true, and the next one starts after that.

- [x] **0. Name, logo, plan.** This file.

- [ ] **1. It boots.**
  The LTS kernel, a static BusyBox and the hand-written `rootfs/`, packed into an initramfs.
  *Done when:* `make run` reaches a login prompt, `rc.S` and `rc.M` run cleanly, the network comes up over
  DHCP, and `poweroff` shuts down cleanly through `rc.6`.

- [ ] **2. The toolchain.**
  Build binutils, GCC and glibc from source for `x86_64-valence-linux-gnu`, then rebuild BusyBox and the
  kernel with it.
  *Done when:* nothing in the image was built by the host's compiler.

- [ ] **3. Packages.**
  `installpkg`, `removepkg`, `upgradepkg` and `makepkg` as shell scripts, plus one build script per package,
  and `pkg`, which fetches signed packages from a repository and resolves dependencies. The base system
  becomes a set of packages. The design is in "Packages" below.
  *Done when:* the base system is installed by `installpkg` alone, `removepkg` takes a package back out
  cleanly, and in QEMU `pkg install` pulls a package and its dependencies from a test repository over HTTP,
  refuses a package or index whose signature or checksum is wrong, and `pkg upgrade` upgrades it.

- [ ] **4. Installing to disk.**
  `setup` partitions the disk (GPT, BIOS boot + EFI + Btrfs), creates the subvolumes, installs the packages,
  and installs GRUB for both BIOS and UEFI. `upgradepkg` snapshots `/` first.
  *Done when:* the ISO installs in QEMU on BIOS and on UEFI, and a QEMU test breaks an upgrade on purpose, rolls
  back, and boots.

- [ ] **5. A full base system.**
  The tools people expect, with man pages: whatever "Core tools" settles on, plus networking, `ssh`, an editor
  and `man`.
  *Done when:* you can administer a Valence machine with nothing but what the base install gives you.

- [ ] **6. The desktop.**
  Mesa, Qt, KDE Frameworks, Plasma, SDDM and PipeWire as packages.
  *Done when:* an install from the ISO logs in to Plasma through SDDM.

- [ ] **7. Documentation and the first release.**
  An install guide, an upgrade and recovery guide, and contributing rules (`testing` before `main`). Signed
  packages and ISOs with checksums.
  *Done when:* someone can install Valence from the guide alone.

## Packages

Two layers. The low layer works on local files only and never touches the network; `pkg` sits on top and does
the fetching and the dependency work, then calls the low layer. Everything is a shell script.

**One version of each package per repository.** A repository (a release, or `testing`) is one consistent
snapshot, as in Slackware and OpenBSD. That keeps dependency resolution a graph walk: no version constraints,
no solver. "Upgrade" means the repository's version or build differs from the installed one.

**A package** is `name-version-build-x86_64.txz`: the files, plus an `install/` directory that is read and
removed on install:

- `install/info`: name, version, build, a one-line description, and `depends=` (package names only)
- `install/doinst.sh` (optional): runs after the files are in place
- Config files ship as `/etc/foo.new`; they become `/etc/foo` only if that does not exist yet, so upgrades
  never overwrite local edits

**The database** is `/var/log/packages/<name>`: the `info` header, `reason=explicit` or `reason=dependency`, then
every path the package installed. "Which package owns this file" is a `grep`.

**The low layer:**

- `installpkg file.txz`: refuses to overwrite a file another package owns (`-f` to force), warns about missing
  dependencies but never fetches them
- `removepkg name`: removes the files in its list that no other package also lists
- `upgradepkg file.txz`: takes a Btrfs snapshot of `/`, installs the new version, then removes the files the
  old one had and the new one doesn't
- `makepkg`: runs a build script and packs the result

**A build script** is `pkgs/<name>/build` in this repository:

```sh
name=zlib version=1.3.1 build=1
source=https://zlib.net/zlib-$version.tar.xz
sha256=...
depends=""
build() { ./configure --prefix=/usr && make && make DESTDIR="$PKG" install; }
```

**`pkg`:**

| | |
|---|---|
| `pkg update` | fetch `PACKAGES` and `PACKAGES.sig`, check the signature, keep the index in `/var/lib/pkg` |
| `pkg install name...` | resolve dependencies (deepest first, stop on a cycle), show the plan, download to `/var/cache/pkg`, check each sha256, `installpkg` in order |
| `pkg upgrade` | one snapshot, then `upgradepkg` every package whose version or build differs from the index |
| `pkg remove name` | refuses if an installed package depends on it; `pkg autoremove` removes dependencies nothing needs any more |
| `pkg search word`, `pkg info name` | read the index |

**A repository** is a plain web directory:

```
<mirror>/<release or testing>/x86_64/
  PACKAGES        one line per package: name, version, build, file, size, sha256, depends, description
  PACKAGES.sig    signify signature of PACKAGES
  *.txz
```

The mirror URL is in `/etc/pkg/mirror` and the public keys are in `/etc/pkg/keys/`. Because the signed index holds
every package's sha256, a mirror can be plain HTTP and still can't slip in a changed package; the fetch is
BusyBox `wget` (or `curl` once the full tools are in).

Signing proposal: signify (OpenBSD's tool; `minisign` reads the same keys). It signs one file with a small key
and has nothing to configure, unlike GPG.

## Not decided yet

These are open on purpose. Each gets settled before the phase that needs it.

- **Core tools.** BusyBox throughout, or the full GNU tools on the installed system with BusyBox only in the
  initramfs. (Phase 5.)
- **Package signing.** Proposed: signify (see "Packages"). (Phase 3.)
- **Compression.** `.txz` (xz) or zstd, which unpacks several times faster. (Phase 3.)
- **How rollback is offered.** A command, a boot menu entry, or both. (Phase 4.)
- **Flatpak.** Offered on the desktop or not. (Phase 6.)
- **Hosting.** Where the packages and the ISOs live.

## How the work is done

- Build scripts and sources of truth live in this repository; binaries do not.
- Building happens on a real machine, not in CI.
- Work lands on `testing`. `main` only moves when `testing` has been checked.
