#!/usr/bin/env python3
import re
import sys

sys.path.insert(0, r"E:\iosReturn\tools")
from rename_profile import (  # noqa: E402
    der_tag, der_int, make_self_signed_cert,
    OID_SIGNED_DATA, OID_DATA, OID_SHA1_WITH_RSA,
)
from cryptography.hazmat.primitives import serialization  # noqa: E402
from cryptography.hazmat.primitives.serialization import pkcs7  # noqa: E402


def parse(d):
    i = 0
    fields = []
    while i < len(d):
        tag = d[i]
        n = d[i + 1]
        off = 2
        if n & 0x80:
            nl = n & 0x7F
            n = int.from_bytes(d[i + 2:i + 2 + nl], "big")
            off = 2 + nl
        fields.append((tag, d[i + off:i + off + n]))
        i += off + n
    return fields


orig = open(r"E:\iosReturn\signing\runner.mobileprovision", "rb").read()
ci = parse(orig)
a0 = [f for f in parse(ci[0][1]) if f[0] == 0xA0][0]
sd_content = parse(a0[1][4:])
si_set = [f for f in sd_content if f[0] == 0x31][1]
si_inner = parse(si_set[1])[0]
si_fields = parse(si_inner[1])
apple_sa = [f for f in si_fields if f[0] == 0xA0][0]  # (0xA0, content)
apple_sa_content = apple_sa[1]  # raw 0x30 SEQUENCE TLV

data = orig
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
sig_alg = der_tag(0x30, der_tag(0x06, OID_SHA1_WITH_RSA) + b"\x05\x00")
sig_empty = der_tag(0x04, b"")
cn = b"\x0c" + b"EdgeReturn-CI"
org = b"\x0c" + b"EdgeReturn-CI"
rdn_cn = der_tag(0x30, der_tag(0x06, b"\x55\x04\x03") + cn)
rdn_org = der_tag(0x30, der_tag(0x06, b"\x55\x04\x0a") + org)
issuer_name = der_tag(0x30, der_tag(0x31, rdn_cn) + der_tag(0x31, rdn_org))
ias = der_tag(0x30, issuer_name + der_int(cert.serial_number))


def try_variant(name, signer_infos_tlv):
    sd = der_tag(0x30, der_int(1) + digest_algs + encap + certs_ctx + signer_infos_tlv)
    ci = der_tag(0x30, der_tag(0x06, OID_SIGNED_DATA) + der_tag(0xA0, sd))
    try:
        c = pkcs7.load_der_pkcs7_certificates(ci)
        print(name, "-> OK", len(c))
    except Exception as e:
        print(name, "-> FAIL", e)


# N: Apple's raw signedAttrs verbatim (with Apple's digest/time/mac values)
sa_apple = der_tag(0xA0, apple_sa_content)
try_variant("N apple-SA-verbatim", der_tag(0x31, der_tag(0x30, der_int(1) + ias + digest_alg + sa_apple + sig_alg + sig_empty)))
# O: Apple's signedAttrs but only first 3 attributes (ct, time, md)
attrs = parse(apple_sa_content)
first3 = b"".join(der_tag(t, c) for t, c in attrs[:3])
sa3 = der_tag(0xA0, der_tag(0x30, first3))
try_variant("O apple-SA-first3", der_tag(0x31, der_tag(0x30, der_int(1) + ias + digest_alg + sa3 + sig_alg + sig_empty)))
# P: Apple's signedAttrs but only attrs 1,2,3,5 (skip #4)
sel = b"".join(der_tag(t, c) for t, c in [attrs[0], attrs[1], attrs[2], attrs[4]])
sap = der_tag(0xA0, der_tag(0x30, sel))
try_variant("P apple-SA-1235", der_tag(0x31, der_tag(0x30, der_int(1) + ias + digest_alg + sap + sig_alg + sig_empty)))
