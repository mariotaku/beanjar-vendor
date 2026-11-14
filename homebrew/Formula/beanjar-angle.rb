# SPDX-FileCopyrightText: Mariotaku <git@mariotaku.me> and the Beanjar contributors
# SPDX-License-Identifier: GPL-2.0-or-later
# ANGLE's EGL and OpenGL ES on Metal, built as beanjar-vendor's angle/build.sh builds it: the
# Chromium branch and commit in beanjar-vendor's angle/VERSION and angle/sources, the Metal
# backend only. The source archive is ANGLE's DEPS checkout cut down by beanjar-vendor's
# angle/source.sh, published with beanjar-vendor's release; clang and gn are the prebuilt ones
# ANGLE's DEPS pins (they are not source and differ per architecture), ninja is Homebrew's.
class BeanjarAngle < Formula
  desc "OpenGL ES and EGL on Metal (ANGLE), for Beanjar's QEMU"
  homepage "https://chromium.googlesource.com/angle/angle"
  url "https://github.com/mariotaku/beanjar-vendor/releases/download/angle-8149.29d18232%2Bbeanjar1/angle-8149.29d18232-source.tar.xz"
  version "8149.29d18232+beanjar1"
  sha256 "2dfa4226e05361fb0ee156afdee6848542f11c2152d09165113c44cd5c9ddee0"
  license "BSD-3-Clause"

  keg_only "it is Beanjar's own build, used only by Beanjar's QEMU"

  depends_on "ninja" => :build
  depends_on "python@3.13" => :build
  depends_on xcode: ["16.0", :build] # Metal shader compiler
  depends_on "pkgconf" => :test
  depends_on :macos

  # The toolchain ANGLE's DEPS pins for this commit: Chromium's clang and its llvm-otool
  # (third_party/llvm-build/Release+Asserts), and gn (buildtools/mac)
  on_arm do
    resource "clang" do
      url "https://commondatastorage.googleapis.com/chromium-browser-clang/Mac_arm64/clang-llvmorg-24-init-17044-gc3223914-1.tar.xz"
      sha256 "f9294be515a0096120c497bdb70374e3846baa244f039a68444ff44899510c74"
    end

    resource "llvmobjdump" do
      url "https://commondatastorage.googleapis.com/chromium-browser-clang/Mac_arm64/llvmobjdump-llvmorg-24-init-17044-gc3223914-1.tar.xz"
      sha256 "208ced05108b28a843fd0c9835d8995ce78a8f32e1e809115e39909c43afb64d"
    end

    resource "gn" do
      url "https://chrome-infra-packages.appspot.com/dl/gn/gn/mac-arm64/+/git_revision:ed7fee04cb30b96ed40ef188acfad5417349e399"
      sha256 "761df368eda3518c9a1093e15618232c1884aafa55c49e625ee7226ff4d9c00a"
    end
  end

  on_intel do
    resource "clang" do
      url "https://commondatastorage.googleapis.com/chromium-browser-clang/Mac/clang-llvmorg-24-init-17044-gc3223914-1.tar.xz"
      sha256 "595970106910ebbfa2d1051661a79c7fa728ee6ec211283b0e01909f009b4d1e"
    end

    resource "llvmobjdump" do
      url "https://commondatastorage.googleapis.com/chromium-browser-clang/Mac/llvmobjdump-llvmorg-24-init-17044-gc3223914-1.tar.xz"
      sha256 "fec5be8f8004d80edd6e296f53cf4778c242bfac5b1ac6c0e9ea4b78dd1eb0c8"
    end

    resource "gn" do
      url "https://chrome-infra-packages.appspot.com/dl/gn/gn/mac-amd64/+/git_revision:ed7fee04cb30b96ed40ef188acfad5417349e399"
      sha256 "ee173a255d60258cc2b8fe846d36807315d5ab48de29df63532e90f26f29c8cc"
    end
  end

  # beanjar-vendor's check of its ANGLE tarball
  resource "egl-check", :test do
    url "https://raw.githubusercontent.com/mariotaku/beanjar-vendor/325003ce9244229fa3b63b30531fb11561ef7a6e/angle/egl-check.c"
    sha256 "e7ce272080db6f0f41756a4bc5d4a4c1739342591b0259d6f0001c8a6eb4d26d"
  end

  def install
    llvm = buildpath/"third_party/llvm-build/Release+Asserts"
    resource("clang").stage(llvm)
    resource("llvmobjdump").stage { (llvm/"bin").install Dir["bin/*"] }
    resource("gn").stage(buildpath/"buildtools/mac")
    ENV.prepend_path "PATH", formula_opt_libexec("python@3.13")/"bin"
    # No git metadata in the archive: name the commit for ANGLE's version string
    ENV["ANGLE_UPSTREAM_HASH"] = "29d18232e803"

    cpu = Hardware::CPU.arm? ? "arm64" : "x64"
    args = %W[
      is_debug=false
      is_component_build=false
      target_cpu="#{cpu}"
      symbol_level=0
      angle_enable_metal=true
      angle_enable_gl=false
      angle_enable_vulkan=false
      angle_enable_swiftshader=false
      angle_enable_wgpu=false
      angle_enable_null=false
      angle_build_tests=false
      enable_rust=false
      enable_rust_cxx=false
      use_siso=false
    ]
    gn = buildpath/"buildtools/mac/gn"
    # ANGLE's .gn runs gn's scripts with the prebuilt Python of its DEPS, which the archive leaves
    # out with the other prebuilt tools; nothing in these libraries is Rust, and ninja runs the
    # build rather than siso
    python3 = formula_opt_libexec("python@3.13")/"bin/python3"
    system gn, "gen", "out/Release", "--script-executable=#{python3}", "--args=#{args.join(" ")}"
    system "ninja", "-C", "out/Release", "libEGL", "libGLESv2"

    # Homebrew gives them install names in the keg's opt path
    lib.install "out/Release/libEGL.dylib", "out/Release/libGLESv2.dylib"
    include.install %w[EGL GLES2 GLES3 KHR].map { |d| "include/#{d}" }

    # The licences of the third-party code linked in: each third_party directory the libraries
    # depend on, by gn's account
    third = %w[libEGL libGLESv2].flat_map do |t|
      Utils.safe_popen_read(gn, "desc", "--script-executable=#{python3}", "out/Release", "//:#{t}",
                            "deps", "--all").lines
    end
    third = third.filter_map { |l| l[%r{^//(.*third_party/[^/:]*)}, 1] }.uniq.sort
    names = %w[LICENSE LICENSE.TXT LICENSE.txt LICENSE.md COPYING]
    third.each do |t|
      # buildtools/third_party/libc++ builds what is checked out in third_party/libc++
      dirs = [t, "third_party/#{File.basename(t)}"]
      lic = dirs.product(names.flat_map { |n| [n, "src/#{n}"] }).map { |d, n| buildpath/d/n }.find(&:file?)
      odie "no licence file in #{t}" if lic.nil?
      doc.install lic => "LICENSE-#{File.basename(t)}"
    end

    upstream = version.to_s.sub(/\+beanjar\d+$/, "")
    { "egl" => ["EGL", "libEGL"], "glesv2" => ["GLESv2", "libGLESv2"] }.each do |name, (desc, l)|
      (lib/"pkgconfig/#{name}.pc").write <<~EOS
        prefix=#{opt_prefix}
        libdir=${prefix}/lib
        includedir=${prefix}/include

        Name: #{name}
        Description: ANGLE's #{desc} (Metal)
        Version: #{upstream}
        Libs: -L${libdir} -l#{l.delete_prefix("lib")}
        Cflags: -I${includedir}
      EOS
    end
  end

  test do
    resource("egl-check").stage(testpath)
    system ENV.cc, "egl-check.c", "-o", "egl-check", "-I#{include}", "-L#{lib}", "-lEGL", "-lGLESv2"
    # An EGL display on the Metal backend, an OpenGL ES 3 context, a pixel cleared and read back.
    # Every Apple silicon Mac has Metal; the Intel runners' paravirtual GPU gives ANGLE no
    # display, so there exit status 2 (no Metal) passes, as it does in the tarball's check.
    output = shell_output("./egl-check 2>&1; echo \"exit status $?\"")
    puts output
    if Hardware::CPU.intel? && output.include?("exit status 2")
      opoo "ANGLE's Metal backend did not initialise on this Mac"
    else
      assert_match "exit status 0", output
      assert_match "ANGLE Metal Renderer", output
      assert_match "OpenGL ES 3.", output
      assert_match "cleared and read back a pixel", output
    end
    %w[egl glesv2].each do |m|
      assert_equal "8149.29d18232", shell_output("pkgconf --modversion #{lib}/pkgconfig/#{m}.pc").strip
    end
  end
end
