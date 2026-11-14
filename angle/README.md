# angle: ANGLE with its Metal backend, for macOS

[ANGLE](https://chromium.googlesource.com/angle/angle)'s EGL and OpenGL ES libraries, built for
macOS with only the Metal backend. On a Mac they are how Beanjar gets OpenGL ES at all: QEMU's
OpenGL display code and virglrenderer speak EGL and OpenGL ES, which macOS does not have, and
ANGLE implements both on Metal. libepoxy and virglrenderer ([`virglrenderer/`](../virglrenderer/README.md))
and the macOS QEMU ([`qemu/`](../qemu/README.md)) are built against this tarball.

## Version

`<Chromium branch>.<commit>+beanjar<N>`, for example `8149.29d18232+beanjar1`, in `VERSION`.
ANGLE has no releases; it branches with Chromium, and the commit is the tip of that branch
(`chromium/8149`, which later branches up to 8153 share). `sources` pins ANGLE and depot_tools by
full commit hash.

## How it is built

Upstream ANGLE, unchanged, the way its own documentation builds it (`doc/DevSetup.md`): depot_tools'
`gclient` fetches what ANGLE's `DEPS` pins at that commit (Chromium's build files, its clang, libc++
and the third-party code), then `gn` and `ninja` build `libEGL` and `libGLESv2`. The sources of
ANGLE's test suites (VK-GL-CTS, SwiftShader, catapult, cherry) are left out of the checkout, since
no test is built. The gn arguments, also in `BUILDINFO`:

```
is_debug=false is_component_build=false target_cpu="arm64" symbol_level=0
angle_enable_metal=true angle_enable_gl=false angle_enable_vulkan=false
angle_enable_swiftshader=false angle_enable_wgpu=false angle_enable_null=false
angle_build_tests=false
```

Upstream ANGLE rather than the Xcode project in UTM's WebKit fork (`Source/ThirdParty/ANGLE` of
`utmapp/WebKit`): it is pinned by one commit whose `DEPS` pins everything else, it is the ANGLE
that Chromium ships and fixes, its libraries come out with `@rpath` install names (WebKit's are
set for frameworks inside an app and need rewriting), and nothing is forked. The price is the
checkout, a few GB fetched by `gclient` with its own clang. The workflow caches the tarball by
`build.sh`, `sources`, `VERSION` and `NOTICE`, so the build only runs again when they change.

The Metal shaders are compiled by Xcode's `metal` tool. The macos-15 runners' default Xcode
(16.4) has it; Xcode 26 needs the Metal toolchain downloaded separately.

## The tarball

`angle-<version>-macos-<arch>.tar.xz`, `<arch>` `arm64` or `amd64`. Its root is a relocatable
prefix:

| Path | |
|---|---|
| `lib/libEGL.dylib`, `lib/libGLESv2.dylib` | stripped and ad hoc signed, install names `@rpath/libEGL.dylib` and `@rpath/libGLESv2.dylib`; they link only the system's libraries and frameworks (ANGLE's libc++ is built in) |
| `lib/pkgconfig/egl.pc`, `glesv2.pc` | `prefix=${pcfiledir}/../..` |
| `include/EGL`, `GLES2`, `GLES3`, `KHR` | ANGLE's headers, among them `EGL/eglext_angle.h` |
| `share/doc/angle/` | ANGLE's `LICENSE`, a `LICENSE-<name>` for each third-party directory gn says the libraries depend on, and `NOTICE` |
| `BUILDINFO` | program, version, architecture, macOS, SDK and Xcode versions, the pinned sources, the third-party directories, the gn arguments, and `Links`, what the libraries load (`otool -L`) |

A program using them needs an `LC_RPATH` to the directory they are in.

## Building

`angle/build.sh [OUT]` on a Mac with Xcode and Homebrew (it installs `pkgconf`, `gnu-tar` and
`xz`). The tarball is written to `build/angle/` by default, and `angle/test-tarball.sh` then
unpacks it elsewhere, builds `egl-check.c` against it with pkg-config and runs it: an EGL display
on the Metal backend (`EGL_PLATFORM_ANGLE_TYPE_METAL_ANGLE`), an OpenGL ES 3 context on a
pbuffer, a clear read back with `glReadPixels`, and `GL_RENDERER` printed. Where the Metal backend
cannot start (no Metal device), the check says so and passes, unless `ANGLE_REQUIRE_METAL=1`.

The macOS workflow (`.github/workflows/macos.yml`) runs it on GitHub's macOS runners, which are
virtual machines. They have a Metal device, the paravirtual one of macOS's virtualisation: on the
macos-15 arm64 runners the check reports `ANGLE (Apple, ANGLE Metal Renderer: Apple Paravirtual
device, ...)` and OpenGL ES 3.0 (contexts for 3.1 and later are refused). The build takes
about ten minutes there, most of it `gclient`'s fetch.

## Licence

ANGLE is licensed under the BSD 3-Clause licence; the third-party code in the libraries under
the licences in `share/doc/angle`. The build scripts and the check program here are
GPL-2.0-or-later (the repository's `LICENSE`).
