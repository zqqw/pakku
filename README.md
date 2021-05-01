# pakku

Pakku is a pacman wrapper with additional features, such as AUR support.

## Description

Pakku is the creation of [kitsunyan](https://github.com/kitsunyan)
kitsunyan is busy creating new projects at present, so, for now at least:

[pakku-git](https://aur.archlinux.org/packages/pakku-git/) is maintained by Pakku users and the Nim community.
New code is tested before committing so git head should work OK.

If you encounter issues with pakku-git please open an issue here.
Pull requests for improvements or bug fixes are welcomed.

Basically, pakku supports the following features:

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
```
$ git clone https://aur.archlinux.org/pakku-git.git
$ cd pakku-git
$ makepkg -si
```
To build at an earlier commit, instead of the command above:
```
$ makepkg -o
$ cd src/pakku
$ git log
(find desired commit hash)
$ git checkout <commit hash>
$ cd ../..
$ makepkg -e
```
(Please see the makepkg manpage for more options)

To update pakku-git:
`$ pakku -S pakku-git`
(Unlike regular AUR packages, a -git package will only be flagged as needing an
update if the PKGBUILD is updated, not when the git repo has new commits.)

Pakku should work with Arch based distros although some minor aspects may not,
unless distro specific support is included:
`pakku -Sz` will only work with AUR packages
`pakku -Sn` (to build binary packages from source) won't work.
Managing, searching and updating binary packages along with AUR packages will
function correctly.
