# pakku

Pakku is a pacman wrapper with additional features, such as AUR support.

## Description

Pakku is the creation of [kitsunyan](https://github.com/kitsunyan) who is busy
creating new projects at present, so, for now at least:

[pakku](https://aur.archlinux.org/packages/pakku/) is maintained by Pakku users
and the Nim community. If you encounter issues with Pakku please open an issue
here. Pull requests for improvements or bug fixes are welcomed!

## Features

Basically, Pakku supports the following features:

- Installing packages from AUR
- Viewing files and changes between builds
- Building packages from official repositories
- Removing make dependencies after building
- Searching and querying AUR packages
- Reading comments for AUR packages
- PKGBUILD retrieving
- Pacman integration

In other words, it does the same things any AUR helper is capable of.

The following principles were the basis of the program:

- Pacman-like user interface
- Pacman options support (`--asdeps`, `--needed`, etc)
- Pacman configuration support (output settings, ignored packages, etc)
- Download, ask all questions, and only after that start building
- No PKGBUILD sourcing

## Examples

- Build packages from sources: `pakku -S --build linux linux-headers`
- Query all "dependency islands": `pakku -Qdttt`

## Installation

```shell
$ git clone https://aur.archlinux.org/pakku.git
$ cd pakku
$ makepkg -si
```

For more advanced build options check the
[wiki](https://github.com/zqqw/pakku/wiki/Building-and-modifying-pakku)!

## Some tips

- Pakku has color! To enable it, just enable
[color for Pacman](https://wiki.archlinux.org/title/Color_output_in_console#pacman).
- Pakku has out of the box support for [doas](https://wiki.archlinux.org/title/Doas)!
  To use something other than `sudo` or `doas`, check the `PreferredSudoCommand` configuration option.
- Don't forget to read the `pakku(8)` and `pakku.conf(5)` man pages to read the
full list of features!

## Distribution compatibility

Pakku should work with Arch based distros although some minor aspects may not,
unless distro specific support is included:

- `pakku -Sz` will only work with AUR packages
- `pakku -Sn` (to build binary packages from source) won't work.

Managing, searching and updating binary packages along with AUR packages will
function correctly.
