# virglrenderer: virglrenderer and libepoxy for macOS

[virglrenderer](https://gitlab.freedesktop.org/virgl/virglrenderer), the host side of the guest's
virgl (virtio-gpu 3D) driver, and [libepoxy](https://github.com/anholt/libepoxy), the OpenGL
function loader it and QEMU use, built for macOS against ANGLE's EGL and OpenGL ES from
[`angle/`](../angle/README.md). The macOS QEMU links both. On Debian, Beanjar uses Debian's own
virglrenderer and libepoxy; neither is built here for Linux.

## Version

`<virglrenderer version>+git<date>.<commit>+beanjar<N>`, for example
`1.3.0+git20261111.01637fc7+beanjar1`, in `VERSION`: virglrenderer's version in its `meson.build`
and the commit it is built from, which is on `main` after the 1.3.0 release. The macOS support
is not in any release yet. `sources` pins virglrenderer and libepoxy by full commit hash.

## What is built

- **virglrenderer**, `main` at `01637fc76f59`, with only vrend, its OpenGL (ES) renderer:
  `-Dplatforms=egl -Dvenus=false -Dvideo=false -Dtests=false -Ddrm-renderers=[]`. No Venus, so
  neither MoltenVK nor the render server.
- **libepoxy**, `master` at `d1f952c4565c` (after 1.5.10, which cannot do EGL on macOS), with EGL
  and without GLX or X11: `-Degl=yes -Dglx=no -Dx11=false -Dtests=false`. It finds ANGLE's
  headers through the angle tarball's `egl.pc`.

Both are built with Meson as release builds, with `LC_RPATH @loader_path` so each finds the
other next to itself.

### Patches

`patches/virglrenderer/` are virglrenderer's open merge requests !1713 to !1719, fixes for hosts
whose OpenGL is OpenGL ES 3.0, as ANGLE on Metal is. They were opened on 2026-11-11 against
`main` at `ec7b7cd91a30`, some stacked on others; here they are their seven distinct commits
in order, applied to `01637fc76f59`, where they apply without conflict:

- `0001` (!1713) the blitter's shaders use GLSL ES 3.00 on an ES 3.0 host.
- `0002` (!1714) multisample textures with more samples than the format has are refused.
- `0003` (!1715) limits on what a guest context can make vrend hold.
- `0004` (!1716) integer vertex attributes are typed on OpenGL ES hosts.
- `0005` (!1717) zero-stride integer vertex attributes are read in their format.
- `0006` (!1718) multisample textures through `GL_ANGLE_texture_multisample` on ES 3.0 hosts.
- `0007` (!1719) the closest wrap mode an OpenGL ES host has.

`patches/libepoxy/0001`: libepoxy loads `libEGL.dylib` and `libGLESv2.dylib` by bare names on
macOS, which `dlopen` looks for only in `DYLD_LIBRARY_PATH` and its fallback directories. The
patch names them `@rpath/libEGL.dylib` and so on, so libepoxy finds ANGLE next to itself (its
`LC_RPATH @loader_path`) or on the program's run path.

## The tarball

`virglrenderer-<version>-macos-<arch>.tar.xz`, `<arch>` `arm64` or `amd64`. Its root is a
relocatable prefix, meant to be unpacked into the same directory as the angle tarball:

| Path | |
|---|---|
| `lib/libvirglrenderer.1.dylib`, `lib/libepoxy.0.dylib` | stripped and ad hoc signed, install names `@rpath/<name>`, `LC_RPATH @loader_path`; they link only each other and the system's libraries, and libepoxy loads ANGLE's at run time |
| `lib/pkgconfig/virglrenderer.pc`, `epoxy.pc` | `prefix=${pcfiledir}/../..`; `epoxy.pc` requires `egl`, the angle tarball's |
| `include/virgl/`, `include/epoxy/` | the headers |
| `share/doc/virglrenderer/`, `share/doc/libepoxy/` | the upstream licences and `NOTICE` |
| `BUILDINFO` | program, version, architecture, macOS and SDK versions, the pinned sources, the patches with their SHA-256, the Meson options, `Requires` (the angle tarball it was built against) and `Links` (`otool -L`) |

## Building

`virglrenderer/build.sh ANGLE_TARBALL [OUT]` on a Mac with Xcode and Homebrew (it installs Meson,
Ninja, `pkgconf`, `gnu-tar` and `xz`). The tarball is written to `build/virglrenderer/` by
default, and `virglrenderer/test-tarball.sh` then unpacks it with the angle tarball elsewhere,
builds `virgl-check.c` against both and runs it. The program does what QEMU does: it makes
OpenGL ES contexts on ANGLE's Metal backend through libepoxy's EGL, hands them to virglrenderer
through its callbacks with `VIRGL_RENDERER_USE_GLES`, prints the renderer and the virgl
capability sets, and creates a rendering context and a texture. Where the Metal backend cannot
start, the check says so and passes, unless `ANGLE_REQUIRE_METAL=1`.

## Licence

virglrenderer and libepoxy are licensed under the MIT licence, and so are the patches to them.
The build scripts and the check program here are GPL-2.0-or-later (the repository's `LICENSE`).
