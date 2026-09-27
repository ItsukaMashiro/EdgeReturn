#!/usr/bin/env python3
"""Bisect what the cryptography Rust PKCS7 parser rejects in my signerInfo."""
import datetime
import re
import sys

sys.path.insert(0, r"E:\iosReturn\tools")
from rename_profile import (  # noqa: E402
    der_tag, der_int, make_self_signed_cert,
    OID_SIGNED_DATA, OID_DATA, OID_SHA1_WITH_RSA,
    OID_CONTENT_TYPE, OID_SIGNING_TIME,
)
from cryptography.hazmat.primitives import serialization  # noqa: E402
from cryptography.hazmat.primitives.serialization import pkcs7  # noqa: E402

data = open(r"E:\iosReturn\signing\runner.mobileprovision", "rb").read()
i = data.find(b"\x04\x82")
n = int.from_bytes(data[i + 2:i + 4], "big")
plist = data[i + 4:i + 4 + n].decode("utf-8")
plist = re.sub(
    r"<key>Name</key>\s*<string>.*?</string>",
    "<key>Name</key><string>EdgeReturn-Dev</string>",
    plist, flags=re.S,
).encode("utf-8")

cert, key = make_self_signed_cert("EdgeReturn-CI")
cert_der = cert.public_bytes(serialization.Encoding.DER)

digest_alg = der_tag(0x30, der_tag(0x06, OID_SHA1_WITH_RSA) + b"\x05\x00")
digest_algs = der_tag(0x31, digest_alg)
octet = der_tag(0x04, plist)
encap = der_tag(0x30, der_tag(0x06, OID_DATA) + der_tag(0xA0, octet))
certs_ctx = der_tag(0xA0, cert_der)


def try_variant(name, signer_infos_tlv):
    sd = der_tag(0x30, der_int(1) + digest_algs + encap + certs_ctx + signer_infos_tlv)
    ci = der_tag(0x30, der_tag(0x06, OID_SIGNED_DATA) + der_tag(0xA0, sd))
    try:
        c = pkcs7.load_der_pkcs7_certificates(ci)
        print(name, "-> OK", len(c))
    except Exception as e:
        print(name, "-> FAIL", e)


# A: empty signerInfos
try_variant("A empty signerInfos", der_tag(0x31, b""))
# B: SignerInfo with just version
try_variant("B version-only", der_tag(0x31, der_tag(0x30, der_int(1))))
# C: version + digestAlgorithm
try_variant("C +digestAlg", der_tag(0x31, der_tag(0x30, der_int(1) + digest_alg)))
# D: + empty issuerAndSerial
ias_empty = der_tag(0x30, der_tag(0x30, b"") + der_int(cert.serial_number))
try_variant("D +emptyIAS", der_tag(0x31, der_tag(0x30, der_int(1) + ias_empty + digest_alg)))
# E: + empty BIT STRING signature
sig_empty = der_tag(0x03, b"\x00")
sig_alg = der_tag(0x30, der_tag(0x06, OID_SHA1_WITH_RSA) + b"\x05\x00")
try_variant("E +emptySig", der_tag(0x31, der_tag(0x30, der_int(1) + ias_empty + digest_alg + sig_alg + sig_empty)))
# F: + empty OCTET STRING signature (Apple's field type)
sig_oct = der_tag(0x04, b"")
try_variant("F +emptySigOct", der_tag(0x31, der_tag(0x30, der_int(1) + ias_empty + digest_alg + sig_alg + sig_oct)))
