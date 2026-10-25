#!/bin/sh
# SPDX-License-Identifier: LGPL-2.1-only WITH Independent-modules-exception
# Copyright 2026 Liam Seamus Coughlin
#
# Make the test PKI of the mutual TLS live tests in the directory $1.
# The script writes no key into git: the caller passes a temporary directory.
#
# Files written:
#   ca.crt, ca.key            the trusted root CA
#   otherca.crt               an unrelated root CA (its key stays in the directory)
#   server.crt, server.key    the server certificate for localhost, signed by ca
#   alice.crt, alice.key      a client certificate signed by ca, with SAN names
#   mallory.crt, mallory.key  a client certificate signed by otherca
#   expired.crt, expired.key  a client certificate of ca that expired in 2020
#   selfie.crt, selfie.key    a self-signed client certificate (its own anchor)
#   trust-selfie.pem          ca.crt and selfie.crt in one file
set -eu

DIR=${1:?usage: make_mtls_pki.sh <directory>}
mkdir -p "$DIR"
cd "$DIR"

EC="-newkey ec -pkeyopt ec_paramgen_curve:prime256v1"

cat > ca.cnf <<CNF
[ca]
default_ca = CA_default
[CA_default]
database = index.txt
new_certs_dir = .
serial = serial
default_md = sha256
policy = policy_any
unique_subject = no
copy_extensions = none
[policy_any]
commonName = supplied
organizationName = optional
organizationalUnitName = optional
CNF
: > index.txt
echo 01 > serial

# roots
openssl req -x509 $EC -nodes -keyout ca.key -out ca.crt -days 3650 \
  -subj "/CN=Test Root CA" -addext "basicConstraints=critical,CA:TRUE" \
  -addext "keyUsage=critical,keyCertSign,cRLSign" 2> /dev/null
openssl req -x509 $EC -nodes -keyout otherca.key -out otherca.crt -days 3650 \
  -subj "/CN=Other Root CA" -addext "basicConstraints=critical,CA:TRUE" \
  -addext "keyUsage=critical,keyCertSign,cRLSign" 2> /dev/null

# issue NAME SUBJECT EXTFILE CAKEY CACRT [STARTDATE ENDDATE]
issue() {
  name=$1; subj=$2; ext=$3; cakey=$4; cacrt=$5
  openssl req $EC -nodes -keyout "$name.key" -out "$name.csr" \
    -subj "$subj" 2> /dev/null
  if [ $# -ge 7 ]; then
    dates="-startdate $6 -enddate $7"
  else
    dates="-days 825"
  fi
  openssl ca -config ca.cnf -batch -notext -in "$name.csr" -out "$name.crt" \
    -keyfile "$cakey" -cert "$cacrt" -extfile "$ext" $dates 2> /dev/null
  rm -f "$name.csr"
}

cat > server.ext <<EXT
basicConstraints = CA:FALSE
keyUsage = digitalSignature
extendedKeyUsage = serverAuth
subjectAltName = DNS:localhost,IP:127.0.0.1
EXT
cat > client.ext <<EXT
basicConstraints = CA:FALSE
keyUsage = digitalSignature
extendedKeyUsage = clientAuth
subjectAltName = DNS:alice.example,URI:spiffe://example.org/alice,email:alice@example.org
EXT
cat > plain.ext <<EXT
basicConstraints = CA:FALSE
keyUsage = digitalSignature
extendedKeyUsage = clientAuth
EXT

issue server "/CN=localhost" server.ext ca.key ca.crt
issue alice "/O=Example/OU=Eng/CN=alice" client.ext ca.key ca.crt
issue mallory "/CN=mallory" plain.ext otherca.key otherca.crt
issue expired "/CN=expired" plain.ext ca.key ca.crt 20200101000000Z 20200102000000Z

# a self-signed client certificate: it is its own trust anchor
openssl req -x509 $EC -nodes -keyout selfie.key -out selfie.crt -days 825 \
  -subj "/CN=selfie" -addext "basicConstraints=CA:FALSE" \
  -addext "extendedKeyUsage=clientAuth" 2> /dev/null
cat ca.crt selfie.crt > trust-selfie.pem

rm -f ca.cnf server.ext client.ext plain.ext index.txt* serial* [0-9][0-9].pem
echo "PKI written to $DIR"
