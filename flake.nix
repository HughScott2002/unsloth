{
  description = "Unsloth / Unsloth Studio development shell for NixOS";

  # Why this exists
  # ---------------
  # `./install.sh --local` assumes an FHS layout. On NixOS three assumptions
  # break, and each one fails in a way that is easy to misread:
  #
  #   1. The installer's Python reaches GitHub with urllib/OpenSSL, which finds
  #      no CA bundle. Every prebuilt download dies with CERTIFICATE_VERIFY_FAILED,
  #      the installer falls back to compiling llama.cpp from source, and (with
  #      no nvcc on PATH) that fallback is CPU-only -- silently. Inference then
  #      runs on the CPU with no warning that the GPU was dropped.
  #
  #   2. The downloaded llama.cpp/whisper.cpp prebuilts need libstdc++.so.6,
  #      libssl.so.3 and libcrypto.so.3. The installer's binary preflight builds
  #      its own LD_LIBRARY_PATH, so nix-ld's defaults do not apply and the
  #      binaries are rejected as broken.
  #
  #   3. pip's torch wheels look for libcuda.so.1, which lives in
  #      /run/opengl-driver/lib on NixOS. Without it torch.cuda.is_available()
  #      returns False and training quietly runs on the CPU.
  #
  # This shell supplies the certificates, the libraries and the driver path, so
  # the normal installer flow works unmodified:
  #
  #     nix develop
  #     ./install.sh --local
  #     unsloth studio -p 8888
  #
  # It deliberately does NOT package Unsloth. The installer owns its own uv venv
  # and downloads its own prebuilts; wrapping that in a derivation would mean
  # re-packaging CUDA torch, unsloth-zoo, the Vite frontend and llama.cpp, and
  # would have to be revised on most upstream releases.

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
  };

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = f:
        nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      devShells = forAllSystems (pkgs:
        let
          # Libraries the downloaded prebuilts and the pip-installed wheels
          # resolve at runtime. libstdc++/libgomp come from the gcc lib output;
          # libssl/libcrypto from openssl; zlib is a common wheel dependency.
          runtimeLibs = with pkgs; [
            stdenv.cc.cc.lib
            openssl
            zlib
          ];

          # Native deps for the Tauri desktop app (studio/src-tauri).
          #
          # Debian names come from CI, which is the only authoritative list:
          # studio-tauri-smoke.yml:97 and release-desktop.yml:573. Mapped to
          # nixpkgs one for one:
          #
          #   libwebkit2gtk-4.1-dev -> webkitgtk_4_1  (javascriptcoregtk-4.1 +
          #                            webkit2gtk-4.1 .pc files; propagates
          #                            gtk3 and libsoup_3)
          #   libappindicator3-dev  -> libappindicator-gtk3
          #   librsvg2-dev          -> librsvg
          #   libxdo-dev            -> xdotool
          #   libssl-dev            -> openssl
          #   patchelf              -> patchelf
          #
          # Two of those are cargo cult, kept only so this shell matches what
          # CI proves works. Cargo.lock has no openssl-sys (reqwest resolves to
          # rustls) and no xdo crate -- x11-dl dlopens Xlib instead, which is
          # handled by LD_LIBRARY_PATH below, not by linking libxdo.
          #
          # libappindicator-gtk3 is deliberate, NOT libayatana-appindicator:
          # release-desktop.yml:637 fails the build if the release installs the
          # ayatana dev package. Keep the shell on the same side of that guard.
          tauriBuildInputs = with pkgs; [
            webkitgtk_4_1
            libappindicator-gtk3
            librsvg
            xdotool
            openssl
            gtk3
            libsoup_3          # soup3-sys is in Cargo.lock
            glib
            cairo
            pango
            gdk-pixbuf
            atk
            dbus
            # gdkx11-sys/x11-dl link and dlopen these; needed under X11 and
            # XWayland even though the GTK session here is Wayland.
            xorg.libX11
            xorg.libXcursor
            xorg.libXrandr
            xorg.libXi
          ];
          # Shared driver probe. libcuda.so.1 ships with the kernel driver and
          # must match the running module, so it can never come from nixpkgs.
          # Sets $_unsloth_driver_dir (empty when no driver is present).
          # Both shells need it: `default` for torch during ./install.sh, and
          # `tauri` because the desktop app spawns the same Python backend --
          # without it that backend reports "CPU training backend" on a CUDA box.
          driverProbe = ''
            _unsloth_driver_dir=""
            for _unsloth_d in \
                /run/opengl-driver/lib \
                /usr/lib/x86_64-linux-gnu \
                /usr/lib/aarch64-linux-gnu \
                /usr/lib64 \
                /usr/lib; do
              if [ -e "$_unsloth_d/libcuda.so.1" ]; then
                _unsloth_driver_dir="$_unsloth_d"
                break
              fi
            done
          '';
        in
        {
          default = pkgs.mkShell {
            packages = with pkgs; [
              # Installer toolchain.
              uv
              git
              cacert

              # The installer prefers a system Node when it is new enough
              # (>= 22.12 with npm >= 11); supplying one here avoids the
              # nodejs.org prebuilt download entirely.
              nodejs_24
              bun

              # uv builds the venv against this rather than fetching a
              # python-build-standalone binary that would itself need nix-ld.
              python313

              # Only needed if the prebuilt path is unavailable and llama.cpp
              # has to be compiled. curl.dev is what the installer reports as
              # the missing "libcurl4-openssl-dev".
              cmake
              gcc
              pkg-config
              curl.dev
            ];

            shellHook = ''
              # Fixes (1): a real CA bundle for the installer's Python.
              # Set here rather than as a derivation attribute: stdenv clears
              # SSL_CERT_FILE for build purity (it uses NIX_SSL_CERT_FILE), so an
              # attribute arrives empty in `nix develop`. shellHook runs last.
              export SSL_CERT_FILE="${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
              export REQUESTS_CA_BUNDLE="$SSL_CERT_FILE"

              # Fixes (2) and (3). Impure by necessity -- see driverProbe.
              ${driverProbe}
              # Driver dir appended after the nixpkgs libraries so it cannot
              # shadow them, and omitted entirely when nothing was found.
              export LD_LIBRARY_PATH="${nixpkgs.lib.makeLibraryPath runtimeLibs}''${_unsloth_driver_dir:+:$_unsloth_driver_dir}''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

              # Studio's own launcher prepends torch's bundled CUDA libs and
              # re-execs (studio/backend/run.py), so the CUDA runtime does not
              # need to be set here -- only the driver, above.

              echo "Unsloth dev shell"
              echo "  python $(python3 --version 2>&1 | cut -d' ' -f2) | node $(node --version) | uv $(uv --version 2>&1 | cut -d' ' -f2)"
              if [ -e "''${SSL_CERT_FILE:-}" ]; then
                echo "  ca bundle: ok"
              else
                echo "  ca bundle: MISSING -- prebuilt downloads will fail TLS"
              fi
              if [ -n "$_unsloth_driver_dir" ]; then
                echo "  nvidia driver: $_unsloth_driver_dir"
              else
                echo "  nvidia driver: libcuda.so.1 not found -- CPU only"
                echo "                 NixOS: hardware.nvidia + hardware.graphics.enable"
                echo "                 other: install the vendor driver, or run under nixGL"
              fi
              unset _unsloth_d _unsloth_driver_dir
              echo ""
              echo "  ./install.sh --local     then     unsloth studio -p 8888"
            '';
          };

          # Desktop app shell.
          #
          #     nix develop .#tauri
          #     npm ci --prefix studio          # pinned @tauri-apps/cli
          #     npm install --prefix studio/frontend
          #     cd studio && npx tauri dev
          #
          # Separate from `default` on purpose: the desktop app is a Rust/GTK
          # build and shares nothing with the Python installer path, so nobody
          # running ./install.sh should have to fetch webkitgtk.
          tauri = pkgs.mkShell {
            nativeBuildInputs = with pkgs; [
              pkg-config
              # rust-version = "1.89" in src-tauri/Cargo.toml; nixpkgs 25.11
              # ships 1.91.1.
              cargo
              rustc
              # frontend/package.json engines: ">=22.12.0". beforeDevCommand
              # runs `npm run dev` in studio/frontend, so node is not optional
              # even for a pure `tauri dev`.
              nodejs_24
              patchelf
              # fix-path-env is a git dependency in Cargo.toml.
              git
            ];

            buildInputs = tauriBuildInputs;

            shellHook = ''
              # x11-dl dlopens libX11.so.6 by soname rather than linking it, so
              # the ld-wrapper never writes it into the binary's RUNPATH and
              # dlopen has nowhere to look. Everything else here is linked and
              # would resolve without this; the list is uniform so a future
              # dlopened lib does not need a second diagnosis.
              # The desktop app spawns the same Python backend as the web UI, so
              # it needs the NVIDIA driver and the prebuilt runtime libs too --
              # otherwise the backend logs "CPU training backend" on a CUDA host
              # and llama-server prebuilts fail their preflight. Both are
              # appended AFTER the GTK/WebKit inputs so they cannot shadow the
              # exact webkit/gtk versions this shell pins.
              ${driverProbe}
              export LD_LIBRARY_PATH="${nixpkgs.lib.makeLibraryPath tauriBuildInputs}:${nixpkgs.lib.makeLibraryPath runtimeLibs}''${_unsloth_driver_dir:+:$_unsloth_driver_dir}''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

              # WebKit's network stack is libsoup, and libsoup gets TLS from a
              # GIO module. Without glib-networking every https:// request from
              # inside the webview fails -- which for this app means the
              # huggingface.co origins the CSP allows (tauri.conf.json) go dead
              # while the app itself looks fine. Prepended, but a GNOME session
              # already exports this, so the inherited value is kept.
              export GIO_EXTRA_MODULES="${pkgs.glib-networking}/lib/gio/modules''${GIO_EXTRA_MODULES:+:$GIO_EXTRA_MODULES}"

              # tauri-plugin-dialog opens a GTK file chooser, which aborts the
              # process if org.gtk.Settings.FileChooser is not installed.
              # Appended: a desktop session's own schemas win.
              export XDG_DATA_DIRS="''${XDG_DATA_DIRS:+$XDG_DATA_DIRS:}${pkgs.gtk3}/share/gsettings-schemas/${pkgs.gtk3.name}:${pkgs.gsettings-desktop-schemas}/share/gsettings-schemas/${pkgs.gsettings-desktop-schemas.name}"

              # Deliberately NOT setting WEBKIT_DISABLE_DMABUF_RENDERER.
              # src/linux_webkit.rs treats the presence of that variable -- or
              # of WEBKIT_DMABUF_RENDERER_FORCE_SHM -- as an operator override
              # and stops applying its own workaround. On webkitgtk >= 2.44
              # (25.11 has 2.52) it picks the newer shared-memory path itself
              # under Wayland. Setting the legacy variable here would silence
              # that and hand you the worse of the two. If the window comes up
              # blank anyway, export it by hand for that one run.

              echo "Unsloth tauri shell"
              echo "  rustc $(rustc --version | cut -d' ' -f2) | node $(node --version) | webkit2gtk-4.1 $(pkg-config --modversion webkit2gtk-4.1 2>/dev/null || echo MISSING)"
              echo "  session: ''${XDG_SESSION_TYPE:-unknown}"
              if [ -n "$_unsloth_driver_dir" ]; then
                echo "  nvidia driver: $_unsloth_driver_dir"
              else
                echo "  nvidia driver: not found -- backend will report CPU"
              fi
              unset _unsloth_d _unsloth_driver_dir
              echo ""
              echo "  npm ci --prefix studio && npm install --prefix studio/frontend"
              echo "  cd studio && npx tauri dev"
            '';
          };
        });
    };
}
