#!/usr/bin/env python3
import datetime
import hashlib
import re
import sys

sys.path.insert(0, r"E:\iosReturn\tools")
from rename_profile import (  # noqa: E402
    der_tag, der_int, make_self_signed_cert,
    OID_SIGNED_DATA, OID_DATA, OID_SHA1_WITH_RSA,
    OID_CONTENT_TYPE, OID_SIGNING_TIME, OID_MESSAGE_DIGEST,
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
sig_alg = der_tag(0x30, der_tag(0x06, OID_SHA1_WITH_RSA) + b"\x05\x00")
sig_empty = der_tag(0x04, b"")
cn = b"\x0c" + b"EdgeReturn-CI"
org = b"\x0c" + b"EdgeReturn-CI"
rdn_cn = der_tag(0x30, der_tag(0x06, b"\x55\x04\x03") + cn)
rdn_org = der_tag(0x30, der_tag(0x06, b"\x55\x04\x0a") + org)
issuer_name = der_tag(0x30, der_tag(0x31, rdn_cn) + der_tag(0x31, rdn_org))
ias = der_tag(0x30, issuer_name + der_int(cert.serial_number))

md = hashlib.sha1(plist).digest()
utc = datetime.datetime.now(datetime.timezone.utc).strftime("%y%m%d%H%M%SZ").encode()

a_ct = der_tag(0x30, der_tag(0x06, OID_CONTENT_TYPE) + der_tag(0x31, der_tag(0x06, OID_SIGNED_DATA)))
a_md = der_tag(0x30, der_tag(0x06, OID_MESSAGE_DIGEST) + der_tag(0x31, der_tag(0x04, md)))
a_time = der_tag(0x30, der_tag(0x06, OID_SIGNING_TIME) + der_tag(0x31, der_tag(0x17, utc)))


def try_variant(name, signer_infos_tlv):
    sd = der_tag(0x30, der_int(1) + digest_algs + encap + certs_ctx + signer_infos_tlv)
    ci = der_tag(0x30, der_tag(0x06, OID_SIGNED_DATA) + der_tag(0xA0, sd))
    try:
        c = pkcs7.load_der_pkcs7_certificates(ci)
        print(name, "-> OK", len(c))
    except Exception as e:
        print(name, "-> FAIL", e)


# K: ct + md + time
sa = der_tag(0xA0, der_tag(0x30, a_ct + a_md + a_time))
try_variant("K ct+md+time", der_tag(0x31, der_tag(0x30, der_int(1) + ias + digest_alg + sa + sig_alg + sig_empty)))
# L: only md
sa2 = der_tag(0xA0, der_tag(0x30, a_md))
try_variant("L md-only", der_tag(0x31, der_tag(0x30, der_int(1) + ias + digest_alg + sa2 + sig_alg + sig_empty)))
# M: ct + md (no time)
sa3 = der_tag(0xA0, der_tag(0x30, a_ct + a_md))
try_variant("M ct+md", der_tag(0x31, der_tag(0x30, der_int(1) + ias + digest_alg + sa3 + sig_alg + sig_empty)))
