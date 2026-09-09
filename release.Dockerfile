# The release builder (docs/SDL3.md). The shipped binary's glibc floor is set by whatever
# links it, so the WHOLE release builds in here — kernel, deps and plugins — not just SDL.
# almalinux:8 is the oldest base still receiving updates: glibc 2.28, wayland 1.21 (SDL needs
# >= 1.18), repos alive until 2029, no EOL sources dance. Dev builds stay native; this image
# is a release concern only (release.yml).
#
# Odin and zig are fully static binaries, so they drop in unchanged. Nothing compiles from
# source here except libdecor, which el8 does not package: SDL dlopens it at run time and
# only needs its headers and .pc to build the arm.
FROM almalinux:8

# clang is Odin's linker driver; the X11/wayland/EGL headers feed SDL's dlopened backends,
# so they shape the build and never the binary's needs. weak deps off keeps the image lean.
RUN dnf -y install --setopt=install_weak_deps=False \
        gcc gcc-c++ clang make cmake git curl tar xz unzip patch pkgconf-pkg-config \
        libX11-devel libXext-devel libXrandr-devel libXcursor-devel libXi-devel \
        libXfixes-devel libXrender-devel libXScrnSaver-devel \
        wayland-devel wayland-protocols-devel libxkbcommon-devel \
        mesa-libGL-devel mesa-libEGL-devel cairo-devel pango-devel \
        python3.12 python3.12-pip \
    && dnf clean all

# el8's own python is too old for meson; ninja rides the same pip.
RUN python3.12 -m pip install --no-cache-dir meson ninja

ARG LIBDECOR_VERSION=0.2.2
RUN curl -fsSL "https://gitlab.freedesktop.org/libdecor/libdecor/-/archive/${LIBDECOR_VERSION}/libdecor-${LIBDECOR_VERSION}.tar.gz" \
        | tar xz -C /tmp \
    && cd "/tmp/libdecor-${LIBDECOR_VERSION}" \
    && meson setup build --prefix=/usr -Ddemo=false -Ddbus=disabled -Dgtk=disabled \
    && ninja -C build install \
    && rm -rf "/tmp/libdecor-${LIBDECOR_VERSION}"

# Pinned to the toolchain a dev machine runs (mise.toml pins zig the same way), so the
# release and a local build cannot differ by compiler.
ARG ODIN_VERSION=dev-2026-08
RUN mkdir -p /opt/odin \
    && curl -fsSL "https://github.com/odin-lang/Odin/releases/download/${ODIN_VERSION}/odin-linux-amd64-${ODIN_VERSION}.tar.gz" \
        | tar xz --strip-components=1 -C /opt/odin

ARG ZIG_VERSION=0.16.0
RUN mkdir -p /opt/zig \
    && curl -fsSL "https://ziglang.org/download/${ZIG_VERSION}/zig-x86_64-linux-${ZIG_VERSION}.tar.xz" \
        | tar xJ --strip-components=1 -C /opt/zig

ENV PATH="/opt/odin:/opt/zig:${PATH}"
WORKDIR /work
