# SPDX-FileCopyrightText: Mariotaku <git@mariotaku.me> and the Beanjar contributors
# SPDX-License-Identifier: GPL-2.0-or-later
# Beanjar's patched QEMU, built as beanjar-vendor's qemu/build-macos.sh builds it: the release in
# beanjar-vendor's qemu/VERSION with its patches, aarch64-softmmu only, with the D-Bus display and
# audio, CoreAudio, slirp, virtio-9p, usb-redir, and OpenGL through beanjar-libepoxy and
# beanjar-virglrenderer on beanjar-angle. The rest (GLib, pixman, libslirp...) is Homebrew's.
class BeanjarQemu < Formula
  desc "Beanjar's patched QEMU for webOS TV virtual machines"
  homepage "https://github.com/mariotaku/beanjar-vendor"
  url "https://download.qemu.org/qemu-10.0.2.tar.xz"
  version "10.0.2+beanjar1"
  sha256 "ef786f2398cb5184600f69aef4d5d691efd44576a3cff4126d38d4c6fec87759"
  license "GPL-2.0-only"

  keg_only "it is Beanjar's own build and would clash with Homebrew's qemu"

  depends_on "ninja" => :build
  depends_on "pkgconf" => :build
  depends_on "python@3.15" => :build
  depends_on arch: :arm64
  depends_on "dtc"
  depends_on "glib"
  depends_on "libpng"
  depends_on "libslirp"
  depends_on "libusb"
  depends_on :macos
  depends_on "pixman"
  depends_on "usbredir"
  depends_on "webosbrew/beanjar/beanjar-angle"
  depends_on "webosbrew/beanjar/beanjar-libepoxy"
  depends_on "webosbrew/beanjar/beanjar-virglrenderer"

  # QEMU's configure builds its Python venv with distlib, which current pip no longer carries
  resource "distlib" do
    url "https://files.pythonhosted.org/packages/c1/2b/238f02a4927fa2e27aa995371d240a468b52e42eae44a678434aff736b38/distlib-0.4.4-py2.py3-none-any.whl"
    sha256 "cf09d55b1e85a89576b036aeb71550bfd68320f3f21761ca329eadadad918638"
  end

  # The files of QEMU's data directory that Beanjar's VMs load, and the script that deletes the
  # rest (edk2, SeaBIOS and the other architectures' firmware, keymaps), as build-macos.sh does
  resource "share-keep" do
    url "https://raw.githubusercontent.com/mariotaku/beanjar-vendor/23c54cf31d27a9bd842b49e544137cb3f9cdcd1c/qemu/share-keep"
    sha256 "2ca33e1f0f2d8b51c0d6a528ec5a3eb34478a90a50c3adaad950127507100823"
  end

  resource "share-trim" do
    url "https://raw.githubusercontent.com/mariotaku/beanjar-vendor/23c54cf31d27a9bd842b49e544137cb3f9cdcd1c/qemu/share-trim.sh"
    sha256 "d135ae583215e55de04ac6b9c1f6472a0288cc8b13498f005abe57d75f11939c"
  end

  # Beanjar's EGL and D-Bus display patches, as beanjar-vendor carries them
  patch do
    url "https://raw.githubusercontent.com/mariotaku/beanjar-vendor/325003ce9244229fa3b63b30531fb11561ef7a6e/qemu/patches/0001-ui-egl-add-a-surfaceless-EGL-display-for-hosts-witho.patch"
    sha256 "1ac3c007c417f8722ef6df7c3bd5458e127d5cd97725223db114e0c98bea15c2"
  end

  patch do
    url "https://raw.githubusercontent.com/mariotaku/beanjar-vendor/325003ce9244229fa3b63b30531fb11561ef7a6e/qemu/patches/0002-ui-egl-egl_fb_read_rect-honour-y-accept-a8r8g8b8.patch"
    sha256 "4b1f15e80fffbd1efade7683cfe44777df39ed0b8f7a5cb8c484eeb942980821"
  end

  patch do
    url "https://raw.githubusercontent.com/mariotaku/beanjar-vendor/325003ce9244229fa3b63b30531fb11561ef7a6e/qemu/patches/0003-ui-dbus-read-GL-scanouts-back-when-they-cannot-be-ex.patch"
    sha256 "0d1b507221e3d1379ceed71ef4c1501ffbd58c2fb0a91dc75be36f4d427f0042"
  end

  patch do
    url "https://raw.githubusercontent.com/mariotaku/beanjar-vendor/325003ce9244229fa3b63b30531fb11561ef7a6e/qemu/patches/0004-ui-dbus-drop-a-listener-when-its-connection-closes.patch"
    sha256 "7478c58a43a42179d608f7b01a3e713764a03200419ddb4220a2bda77c2582e0"
  end

  def install
    python3 = formula_opt_bin("python@3.15")/"python3.15"
    system python3, "-m", "venv", buildpath/"venv"
    # pip wants the wheel under its own name
    whl = buildpath/"distlib-0.4.4-py2.py3-none-any.whl"
    cp resource("distlib").cached_download, whl
    system buildpath/"venv/bin/python3", "-m", "pip", "install", "--no-deps", "--no-index", whl
    # Only aarch64-softmmu, with what a Mac can give Beanjar's launcher (as in build-macos.sh):
    # OpenGL and virglrenderer, the D-Bus display and audio, CoreAudio, slirp, virtio-9p, PNG for
    # QMP screendump, usb-redir and usb-host. No cocoa, SDL, GTK, VNC, SPICE or curses display,
    # no tools. HVF stays QEMU's default.
    args = %W[
      --prefix=#{prefix}
      --cc=#{ENV.cc}
      --host-cc=#{ENV.cc}
      --python=#{buildpath}/venv/bin/python3
      --target-list=aarch64-softmmu
      --disable-download
      --disable-modules
      --disable-docs
      --disable-user
      --disable-tools
      --disable-guest-agent
      --enable-opengl
      --enable-virglrenderer
      --enable-dbus-display
      --enable-slirp
      --enable-fdt=system
      --enable-virtfs
      --enable-pixman
      --enable-png
      --disable-cocoa
      --disable-sdl
      --disable-gtk
      --disable-vnc
      --disable-spice
      --disable-curses
      --audio-drv-list=coreaudio
      --enable-coreaudio
      --disable-curl
      --disable-gnutls
      --disable-nettle
      --disable-gcrypt
      --disable-capstone
      --disable-lzo
      --disable-bzip2
      --disable-zstd
      --enable-libusb
      --enable-usb-redir
      --disable-smartcard
      --disable-libssh
    ]
    mkdir "build" do
      system "../configure", *args
      system "make", "V=1"
      system "make", "install"
    end
    # Only the data files share-keep lists for aarch64; share-trim.sh fails if one is missing
    trim = buildpath/"share-trim"
    trim.mkpath
    cp resource("share-keep").cached_download, trim/"share-keep"
    cp resource("share-trim").cached_download, trim/"share-trim.sh"
    system "sh", trim/"share-trim.sh", share/"qemu", "aarch64"
  end

  test do
    qemu = bin/"qemu-system-aarch64"
    assert_match "QEMU emulator version 10.0.2", shell_output("#{qemu} --version")
    assert_match(/^dbus$/, shell_output("#{qemu} -display help"))
    audio = shell_output("#{qemu} -audiodev help")
    %w[coreaudio dbus].each { |a| assert_match(/^#{a}$/, audio) }
    devices = shell_output("#{qemu} -device help")
    %w[virtio-gpu-gl-pci virtio-gpu-pci usb-redir virtio-9p-pci].each do |d|
      assert_match "name \"#{d}\"", devices
    end
    # OpenGL through our libepoxy and virglrenderer, not another copy
    links = shell_output("otool -L #{qemu}")
    assert_match "beanjar-libepoxy/lib/libepoxy", links
    assert_match "beanjar-virglrenderer/lib/libvirglrenderer", links
    # HVF needs the hypervisor entitlement; QEMU's own install signs with it
    system "codesign", "--verify", "--verbose", qemu
    assert_match "com.apple.security.hypervisor", shell_output("codesign -d --entitlements - #{qemu} 2>&1")

    # share/qemu holds only what share-keep lists
    assert_equal ["efi-virtio.rom"], (share/"qemu").children.map { |f| f.basename.to_s }.sort

    # A VM with the launcher's machine and devices but no guest (a -kernel of zeros, the D-Bus
    # display in peer-to-peer mode) starts paused and answers QMP's query-status on a unix socket,
    # then quits. Its devices load what they need from share/qemu when they are created:
    # virtio-net-pci its option ROM
    require "json"
    require "socket"
    sock = testpath/"qmp.sock"
    kernel = testpath/"kernel"
    kernel.binwrite("\0" * 4096)
    pid = spawn qemu.to_s, "-M", "virt", "-cpu", "max,pauth=off", "-m", "256", "-nodefaults", "-S",
                "-display", "dbus,p2p=yes", "-kernel", kernel.to_s,
                "-device", "virtio-gpu-pci",
                "-device", "pci-bridge,id=disks,chassis_nr=1,shpc=off",
                "-drive", "if=none,id=disk0,driver=null-co,read-zeroes=on",
                "-device", "virtio-blk-pci,drive=disk0,bus=disks,addr=0x1",
                "-netdev", "user,id=net0", "-device", "virtio-net-pci,netdev=net0",
                "-fsdev", "local,id=share,path=#{testpath},security_model=none,readonly=on",
                "-device", "virtio-9p-pci,fsdev=share,mount_tag=share",
                "-device", "virtio-rng-pci", "-device", "virtio-keyboard-pci", "-device", "virtio-tablet-pci",
                "-chardev", "null,id=con", "-device", "virtio-serial-pci", "-device", "virtconsole,chardev=con",
                "-device", "qemu-xhci", "-device", "virtio-balloon-pci",
                "-audiodev", "dbus,id=snd0", "-device", "virtio-sound-pci,audiodev=snd0,streams=1",
                "-qmp", "unix:#{sock},server=on,wait=off", [:out, :err] => (testpath/"vm.log").to_s
    begin
      100.times do
        break if sock.exist?

        sleep 0.1
      end
      UNIXSocket.open(sock.to_s) do |s|
        greeting = JSON.parse(s.gets)
        assert_equal "10.0.2", greeting["QMP"]["version"]["qemu"].values_at("major", "minor", "micro").join(".")
        command = lambda do |name|
          s.puts({ execute: name }.to_json)
          loop do
            reply = JSON.parse(s.gets)
            break reply unless reply.key?("event")
          end
        end
        assert command.call("qmp_capabilities").key?("return")
        assert_equal "prelaunch", command.call("query-status")["return"]["status"]
        command.call("quit")
      end
      Process.wait(pid)
      assert_predicate $CHILD_STATUS, :success?, (testpath/"vm.log").read
    ensure
      begin
        Process.kill("TERM", pid)
        Process.wait(pid)
      rescue Errno::ESRCH, Errno::ECHILD
        nil
      end
    end
  end
end
