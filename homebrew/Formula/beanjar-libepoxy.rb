# SPDX-FileCopyrightText: Mariotaku <git@mariotaku.me> and the Beanjar contributors
# SPDX-License-Identifier: GPL-2.0-or-later
# libepoxy with EGL on ANGLE, built as beanjar-vendor's virglrenderer/build.sh builds it: the
# commit in beanjar-vendor's virglrenderer/sources, with its patch so that libepoxy loads ANGLE's
# libraries by @rpath, and a run path to beanjar-angle so that they are found there.
class BeanjarLibepoxy < Formula
  desc "OpenGL function pointer library with EGL on ANGLE, for Beanjar's QEMU"
  homepage "https://github.com/anholt/libepoxy"
  url "https://github.com/anholt/libepoxy/archive/d1f952c4565c389d82fd1657153e84e050f35b27.tar.gz"
  version "1.5.11+git20260403.d1f952c4+beanjar1"
  sha256 "a6f08482749647394c36963c030ba97710ef49355677a1564e7d6c1211d628d5"
  license "MIT"

  keg_only "it is Beanjar's own build, used only by Beanjar's QEMU"

  depends_on "meson" => :build
  depends_on "ninja" => :build
  depends_on "pkgconf" => [:build, :test]
  depends_on arch: :arm64
  depends_on :macos
  depends_on "webosbrew/beanjar/beanjar-angle"

  patch do
    url "https://raw.githubusercontent.com/mariotaku/beanjar-vendor/325003ce9244229fa3b63b30531fb11561ef7a6e/virglrenderer/patches/libepoxy/0001-dispatch_common-load-ANGLE-s-libraries-by-rpath-on-m.patch"
    sha256 "3c04d64f15cb275ef36d1998797d91a3bcbb771f4f1c03e64f79c3ac486e38fe"
  end

  def install
    # libepoxy dlopens @rpath/libEGL.dylib and @rpath/libGLESv2.dylib (the patch)
    ENV.append "LDFLAGS", "-Wl,-rpath,#{formula_opt_lib("webosbrew/beanjar/beanjar-angle")}"
    system "meson", "setup", "build", *std_meson_args,
           "-Degl=yes", "-Dglx=no", "-Dx11=false", "-Dtests=false", "-Ddocs=false"
    system "meson", "compile", "-C", "build", "--verbose"
    system "meson", "install", "-C", "build"
  end

  test do
    assert_equal "1", shell_output("pkgconf --variable=epoxy_has_egl #{lib}/pkgconfig/epoxy.pc").strip
    # libepoxy finds ANGLE's libEGL by its run path (it aborts if it cannot load it) and
    # initialises a display on it
    (testpath/"test.c").write <<~C
      #include <stdio.h>
      #include <epoxy/egl.h>

      int main(void)
      {
        EGLDisplay dpy = eglGetDisplay(EGL_DEFAULT_DISPLAY);
        EGLint major, minor;
        if (dpy == EGL_NO_DISPLAY || !eglInitialize(dpy, &major, &minor)) {
          fprintf(stderr, "no EGL display: 0x%04x\\n", eglGetError());
          return 2;
        }
        printf("EGL %d.%d %s, epoxy_egl_version %d\\n", major, minor,
               eglQueryString(dpy, EGL_VERSION), epoxy_egl_version(dpy));
        eglTerminate(dpy);
        return 0;
      }
    C
    ENV.prepend_path "PKG_CONFIG_PATH", formula_opt_lib("webosbrew/beanjar/beanjar-angle")/"pkgconfig"
    ENV.prepend_path "PKG_CONFIG_PATH", lib/"pkgconfig"
    system ENV.cc, "test.c", "-o", "test", *shell_output("pkgconf --cflags --libs epoxy").split
    output = shell_output("./test 2>&1")
    puts output
    assert_match "ANGLE", output
  end
end
