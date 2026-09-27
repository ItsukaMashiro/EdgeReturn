#!/usr/bin/env python3
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
sig_alg = der_tag(0x30, der_tag(0x06, OID_SHA1_WITH_RSA) + b"\x05\x00")
sig_oct_empty = der_tag(0x04, b"")
ias_empty = der_tag(0x30, der_tag(0x30, b"") + der_int(cert.serial_number))


def try_variant(name, signer_infos_tlv):
    sd = der_tag(0x30, der_int(1) + digest_algs + encap + certs_ctx + signer_infos_tlv)
    ci = der_tag(0x30, der_tag(0x06, OID_SIGNED_DATA) + der_tag(0xA0, sd))
    try:
        c = pkcs7.load_der_pkcs7_certificates(ci)
        print(name, "-> OK", len(c))
    except Exception as e:
        print(name, "-> FAIL", e)


# G: F + empty signedAttrs [0] wrapper
sa_empty = der_tag(0xA0, der_tag(0x30, b""))
try_variant("G +emptySignedAttrs", der_tag(0x31, der_tag(0x30, der_int(1) + ias_empty + digest_alg + sa_empty + sig_alg + sig_oct_empty)))
# H: G + real issuer name
cn = b"\x0c" + b"EdgeReturn-CI"
org = b"\x0c" + b"EdgeReturn-CI"
rdn_cn = der_tag(0x30, der_tag(0x06, b"\x55\x04\x03") + cn)
rdn_org = der_tag(0x30, der_tag(0x06, b"\x55\x04\x0a") + org)
issuer_name = der_tag(0x30, der_tag(0x31, rdn_cn) + der_tag(0x31, rdn_org))
ias_real = der_tag(0x30, issuer_name + der_int(cert.serial_number))
try_variant("H +realIssuer", der_tag(0x31, der_tag(0x30, der_int(1) + ias_real + digest_alg + sa_empty + sig_alg + sig_oct_empty)))
# I: H + Apple-style signedAttrs content
import hashlib
md = hashlib.sha1(plist).digest()
import datetime
utc = datetime.datetime.now(datetime.timezone.utc).strftime("%y%m%d%H%M%SZ").encode()
a_ct = der_tag(0x30, der_tag(0x06, OID_CONTENT_TYPE) + der_tag(0x31, der_tag(0x06, OID_SIGNED_DATA)))
a_time = der_tag(0x30, der_tag(0x06, OID_SIGNING_TIME) + der_tag(0x31, der_tag(0x17, utc)))
sa_real = der_tag(0xA0, der_tag(0x30, a_ct + a_time))
try_variant("I +realSignedAttrs", der_tag(0x31, der_tag(0x30, der_int(1) + ias_real + digest_alg + sa_real + sig_alg + sig_oct_empty)))
# J: I + real signature
k = key.key_size // 8
digest_info = b"\x30\x21" b"\x30\x09\x06\x05" + OID_SHA1_WITH_RSA + b"\x05\x00" b"\x04\x14" + md
ps_len = k - 3 - len(digest_info)
em = b"\x00\x01" + b"\xff" * ps_len + b"\x00" + digest_info
pn = key.private_numbers()
m = int.from_bytes(em, "big")
s = pow(m, pn.d, pn.public_numbers.n)
sig = s.to_bytes(k, "big")
try_variant("J +realSig", der_tag(0x31, der_tag(0x30, der_int(1) + ias_real + digest_alg + sa_real + sig_alg + der_tag(0x04, sig))))
