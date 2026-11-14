# SPDX-FileCopyrightText: Mariotaku <git@mariotaku.me> and the Beanjar contributors
# SPDX-License-Identifier: GPL-2.0-or-later
# virglrenderer on OpenGL ES (ANGLE), built as beanjar-vendor's virglrenderer/build.sh builds
# it: the commit of main in beanjar-vendor's virglrenderer/sources, with its seven patches for
# OpenGL ES hosts, vrend only (no Venus, video or DRM renderers).
class BeanjarVirglrenderer < Formula
  include Language::Python::Virtualenv

  desc "VirGL 3D renderer on OpenGL ES (ANGLE), for Beanjar's QEMU"
  homepage "https://gitlab.freedesktop.org/virgl/virglrenderer"
  # GitLab's generated archives have no stable checksum; the commit pins the source
  url "https://gitlab.freedesktop.org/virgl/virglrenderer.git",
      revision: "01637fc76f59a6a4ccb622de0a1d7530c7073917"
  version "1.3.0+git20261111.01637fc7+beanjar1"
  license "MIT"

  keg_only "it is Beanjar's own build, used only by Beanjar's QEMU"

  depends_on "libyaml" => :build
  depends_on "meson" => :build
  depends_on "ninja" => :build
  depends_on "pkgconf" => [:build, :test]
  depends_on "python-setuptools" => :build
  depends_on "python@3.15" => :build
  depends_on :macos
  depends_on "webosbrew/beanjar/beanjar-angle"
  depends_on "webosbrew/beanjar/beanjar-libepoxy"

  # virglrenderer generates its format tables with PyYAML
  resource "pyyaml" do
    url "https://files.pythonhosted.org/packages/05/8e/961c0007c59b8dd7729d542c61a4d537767a59645b82a0b521206e1e25c2/pyyaml-6.0.3.tar.gz"
    sha256 "d76623373421df22fb4cf8817020cbb7ef15c725b9d5e45f17e189bfc384190f"
  end

  # beanjar-vendor's check of its virglrenderer tarball
  resource "virgl-check", :test do
    url "https://raw.githubusercontent.com/mariotaku/beanjar-vendor/325003ce9244229fa3b63b30531fb11561ef7a6e/virglrenderer/virgl-check.c"
    sha256 "b9f6af7a739fa8000b1c2a29ed07e7a7711eef304e2c5a626177b004d247c90f"
  end

  # Merge requests !1713 to !1719 (OpenGL ES hosts), as beanjar-vendor carries them
  patch do
    url "https://raw.githubusercontent.com/mariotaku/beanjar-vendor/325003ce9244229fa3b63b30531fb11561ef7a6e/virglrenderer/patches/virglrenderer/0001-vrend-blitter-build-GLSL-ES-3.00-shaders-on-ES-3.0-h.patch"
    sha256 "7cc6430a17168db268f7504a2e4fab8b5909f96223b98afadf86eae07590ad74"
  end

  patch do
    url "https://raw.githubusercontent.com/mariotaku/beanjar-vendor/325003ce9244229fa3b63b30531fb11561ef7a6e/virglrenderer/patches/virglrenderer/0002-vrend-refuse-multisample-textures-with-more-samples-.patch"
    sha256 "21827bcd7d8b34f0fecf967ead194753fea7c57fb6a2732196f07370cc33be70"
  end

  patch do
    url "https://raw.githubusercontent.com/mariotaku/beanjar-vendor/325003ce9244229fa3b63b30531fb11561ef7a6e/virglrenderer/patches/virglrenderer/0003-vrend-limit-what-contexts-can-make-vrend-hold.patch"
    sha256 "3209bba0981c550ea0b1976bcdb225c5c8d03b7131979088e8e7fcfea73369dd"
  end

  patch do
    url "https://raw.githubusercontent.com/mariotaku/beanjar-vendor/325003ce9244229fa3b63b30531fb11561ef7a6e/virglrenderer/patches/virglrenderer/0004-vrend-type-integer-vertex-attributes-on-OpenGL-ES-ho.patch"
    sha256 "5271933bdafb9ee2e3bbccb1f611f5e8ae72a8dc5977015bcbc9a6b9a6ac93cb"
  end

  patch do
    url "https://raw.githubusercontent.com/mariotaku/beanjar-vendor/325003ce9244229fa3b63b30531fb11561ef7a6e/virglrenderer/patches/virglrenderer/0005-vrend-read-zero-stride-integer-vertex-attributes-in-.patch"
    sha256 "9ae48c2f68db5800b79c340c1dfb8b6edbd9f70348040e9b5282d19bb6e50237"
  end

  patch do
    url "https://raw.githubusercontent.com/mariotaku/beanjar-vendor/325003ce9244229fa3b63b30531fb11561ef7a6e/virglrenderer/patches/virglrenderer/0006-vrend-use-GL_ANGLE_texture_multisample-on-ES-3.0-hos.patch"
    sha256 "de20568b57ba81ac1a0048958010fb7480c9f78abca5d286cebd6e112b44d53b"
  end

  patch do
    url "https://raw.githubusercontent.com/mariotaku/beanjar-vendor/325003ce9244229fa3b63b30531fb11561ef7a6e/virglrenderer/patches/virglrenderer/0007-vrend-take-the-closest-wrap-mode-an-OpenGL-ES-host-h.patch"
    sha256 "46af48d92c8f966edc0206b911fad983e8f78f31d14c1f8b18bbbb351c30dabb"
  end

  def install
    venv = virtualenv_create(buildpath/"venv", formula_opt_bin("python@3.15")/"python3.15")
    venv.pip_install resource("pyyaml"), build_isolation: false
    ENV.prepend_path "PYTHONPATH", venv.site_packages

    system "meson", "setup", "build", *std_meson_args,
           "-Dplatforms=egl", "-Dvenus=false", "-Dvideo=false", "-Dtests=false",
           "-Ddrm-renderers=[]", "-Dminigbm_allocation=false"
    system "meson", "compile", "-C", "build", "--verbose"
    system "meson", "install", "-C", "build"
    # no render server or tools: vrend runs in QEMU's process
    rm_r bin if bin.exist?
    rm_r libexec if libexec.exist?
  end

  test do
    resource("virgl-check").stage(testpath)
    angle = Formula["webosbrew/beanjar/beanjar-angle"]
    libepoxy = Formula["webosbrew/beanjar/beanjar-libepoxy"]
    ENV.prepend_path "PKG_CONFIG_PATH", angle.opt_lib/"pkgconfig"
    ENV.prepend_path "PKG_CONFIG_PATH", libepoxy.opt_lib/"pkgconfig"
    ENV.prepend_path "PKG_CONFIG_PATH", lib/"pkgconfig"
    flags = shell_output("pkgconf --cflags --libs epoxy virglrenderer").split
    system ENV.cc, "virgl-check.c", "-o", "virgl-check", *flags
    # OpenGL ES contexts on ANGLE through libepoxy, virglrenderer started on them as QEMU starts
    # it, a context and a texture created. The Intel runners' paravirtual GPU gives ANGLE no
    # display: there exit status 2 (no Metal) passes, as it does in the tarball's check.
    output = shell_output("./virgl-check 2>&1; echo \"exit status $?\"")
    puts output
    if Hardware::CPU.intel? && output.include?("exit status 2")
      opoo "ANGLE's Metal backend did not initialise on this Mac"
    else
      assert_match "exit status 0", output
      assert_match "created a context and a texture", output
    end
  end
end
