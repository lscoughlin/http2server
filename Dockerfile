# Build and check http2server on Linux amd64 in two stages.
#
#   docker build --progress=plain -t http2server-amd64 .
#
# Stage "toolchain" holds every tool and every dependency. It does not read the
# project sources, so Docker keeps its layers in the cache until a build
# argument changes. Stage "build" copies the sources and runs the simple
# checks: the library, the examples and the unit-test suite.
#
# The load, abuse and conformance runs stay on the development machine.
# See doc/verification/toolchain.md.

# ---------------------------------------------------------------------------
# Stage 1: the toolchain
# ---------------------------------------------------------------------------
FROM ubuntu:24.04 AS toolchain

# Free Pascal 3.2.4 has no distribution package and no upstream binary
# archive for Linux. The stage builds the release candidate that the macOS
# development machine uses, from the upstream tag. The Ubuntu package
# (version 3.2.2) is the bootstrap compiler only.
ARG FPC_TAG=release_3_2_4_rc2
# The mORMot2 revision is the pin of NOTICE and of Taskfile.yaml.
ARG MORMOT_REV=b2b195da1e0580058672a88620ef71bb47283eb1
ARG FPC_PREFIX=/opt/fpc
ARG MORMOT_DIR=/opt/mormot2

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates git make binutils gcc libc6-dev \
      fpc openssl libssl3t64 \
 && rm -rf /var/lib/apt/lists/*

# Build the compiler, the run-time library and the packages, then install them.
RUN git clone --depth 1 --branch "${FPC_TAG}" \
      https://gitlab.com/freepascal.org/fpc/source.git /usr/src/fpc \
 && cd /usr/src/fpc \
 && make all OPT="-O2" \
 && make install INSTALL_PREFIX="${FPC_PREFIX}" \
 && "${FPC_PREFIX}/lib/fpc/$(ls "${FPC_PREFIX}/lib/fpc" | head -n 1)/samplecfg" \
      "${FPC_PREFIX}/lib/fpc/$(ls "${FPC_PREFIX}/lib/fpc" | head -n 1)" /etc \
 && ln -sf "${FPC_PREFIX}/bin/fpc" /usr/local/bin/fpc \
 && rm -rf /usr/src/fpc

# Remove the bootstrap compiler, so that no build can use it by mistake. The
# purge also removes /etc/fpc.cfg, which the Ubuntu package owns, so the step
# writes the configuration of the new compiler again after the purge. The
# driver `fpc` looks for the compiler binary `ppcx64` on the search path, so
# the step links it too.
ENV PATH=${FPC_PREFIX}/bin:${PATH}
RUN ver="$(ls "${FPC_PREFIX}/lib/fpc" | head -n 1)" \
 && ln -sf "${FPC_PREFIX}/lib/fpc/${ver}/ppcx64" /usr/local/bin/ppcx64 \
 && apt-get purge -y 'fpc*' 'fp-*' \
 && apt-get autoremove -y \
 && rm -rf /var/lib/apt/lists/* \
 && "${FPC_PREFIX}/lib/fpc/${ver}/samplecfg" "${FPC_PREFIX}/lib/fpc/${ver}" /etc \
 && fpc -iV \
 && fpc -iW

# Fetch the pinned mORMot2 revision.
RUN git init "${MORMOT_DIR}" \
 && git -C "${MORMOT_DIR}" remote add origin https://github.com/synopse/mORMot2.git \
 && git -C "${MORMOT_DIR}" fetch --depth 1 origin "${MORMOT_REV}" \
 && git -C "${MORMOT_DIR}" checkout --detach FETCH_HEAD \
 && test "$(git -C "${MORMOT_DIR}" rev-parse HEAD)" = "${MORMOT_REV}"

# ---------------------------------------------------------------------------
# Stage 2: the build and the simple checks
# ---------------------------------------------------------------------------
FROM toolchain AS build

ARG FPC_PREFIX=/opt/fpc
ARG MORMOT_DIR=/opt/mormot2

# The Makefile reads these variables from the environment.
ENV MORMOT=${MORMOT_DIR}/src \
    OPENSSL_LIBPATH=/usr/lib/x86_64-linux-gnu

WORKDIR /src
COPY . .

# The unit directory depends on the compiler version, so the step reads it.
RUN set -e; \
    export FPC_UNITS="${FPC_PREFIX}/lib/fpc/$(fpc -iV)/units/$(fpc -iTP)-$(fpc -iTO)"; \
    echo "unit directory: ${FPC_UNITS}"; \
    make all examples test

CMD ["/bin/sh", "-c", "ls -l /src/bin"]
