# http2server - Free Pascal HTTP/2 server library
# See doc/verification/toolchain.md for the locked toolchain facts and
# doc/design/fpc-runtime.md for the language facts.
#
#   make          build the library unit
#   make test     build + run the fpcunit suite
#   make examples compile the example programs into bin/
#   make clean    remove build outputs
#
# The platform defaults are chosen by uname. Every variable can be
# overridden from the environment (FPC, FPC_UNITS, MORMOT, OPENSSL_LIBPATH).

FPC        ?= fpc
FPC_VERSION ?= $(shell $(FPC) -iV 2>/dev/null)
FPC_CPU    ?= $(shell $(FPC) -iTP 2>/dev/null)
FPC_OS     ?= $(shell $(FPC) -iTO 2>/dev/null)

# Platform defaults: a Darwin default and a Linux default.
UNAME_S := $(shell uname -s)
ifeq ($(UNAME_S),Darwin)
FPC_UNITS  ?= /usr/local/lib/fpc/$(FPC_VERSION)/units/$(FPC_CPU)-$(FPC_OS)
OPENSSL_LIBPATH ?= /opt/homebrew/opt/openssl@3/lib
else
FPC_UNITS  ?= /usr/lib/fpc/$(FPC_VERSION)/units/$(FPC_CPU)-$(FPC_OS)
OPENSSL_LIBPATH ?= /usr/lib/x86_64-linux-gnu
endif

FPCFLAGS   ?= -O2 -vw -Mdelphi -Fu./src -Fu$(FPC_UNITS)/fcl-fpcunit
# mormot2 provides the TLS/ALPN layer. Unit dirs are on the search path; the
# runtime library path is passed via OPENSSL_LIBPATH because Darwin's system
# dylibs are unusable.
MORMOT      ?= third_party/mORMot2/src
export OPENSSL_LIBPATH
FPCFLAGS   += -Fu$(MORMOT)/core -Fu$(MORMOT)/lib -Fu$(MORMOT)/net -Fu$(MORMOT)/crypt

SRC        = $(wildcard src/*.pas)
EXAMPLESRC = $(wildcard examples/*.pas)
BIN        = bin

.PHONY: all test examples mtls-live clean

all: $(BIN)/libhttp2server.a

$(BIN)/libhttp2server.a: $(SRC) | $(BIN)
	$(FPC) $(FPCFLAGS) -Cn -FE$(BIN) src/Http2Server.pas

$(BIN):
	mkdir -p $(BIN)

test: all | $(BIN)
	$(FPC) $(FPCFLAGS) -Fu./test -FE$(BIN) test/Http2Server.RunTests.pas
	$(BIN)/Http2Server.RunTests --all --format=plain --sparse

# Compile the example programs (smoke build; they are not executed here).
# The directory can be empty or absent; the wildcard yields an empty list.
examples: all | $(BIN)
	@for f in $(EXAMPLESRC); do \
		[ -e "$$f" ] || continue; \
		$(FPC) $(FPCFLAGS) -FE$(BIN) $$f || exit 1; \
	done

# Live validation of mutual TLS against the sibling client. The target needs the
# sibling checkout at HTTP2CLIENT and the openssl command; it puts no load on the
# server. The PKI is made in a fresh directory under bin/ on every run.
HTTP2CLIENT ?= ../http2client/src
MTLS_PKI    = $(BIN)/mtls-pki

mtls-live: all | $(BIN)
	rm -rf $(MTLS_PKI)
	sh tools/certs/make_mtls_pki.sh $(MTLS_PKI)
	$(FPC) $(FPCFLAGS) -Fu$(HTTP2CLIENT) -Fu./test/mtls -FE$(BIN) test/mtls/Http2Server.MtlsLive.pas
	$(BIN)/Http2Server.MtlsLive $(MTLS_PKI)

clean:
	rm -rf $(BIN) src/*.o src/*.ppu test/*.o test/*.ppu examples/*.o examples/*.ppu
