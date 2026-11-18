# Build environment. Enter with `nix-shell`, then `make`.
{ pkgs ? import <nixpkgs> { } }:

pkgs.mkShell {
  packages = with pkgs; [
    gnumake gcc binutils
    flex bison bc perl
    elfutils openssl pkg-config ncurses
    cpio gzip xz bzip2 curl
    glibc.static          # busybox links static
    qemu
  ];
  # The nixpkgs cc-wrapper's hardening flags fight with kernel/busybox builds.
  hardeningDisable = [ "all" ];
}
