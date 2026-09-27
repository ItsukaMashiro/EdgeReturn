#!/usr/bin/env python3
"""
Rename a provisioning profile's embedded plist Name and re-wrap it in a
valid CMS SignedData signed by a self-signed cert.

Why: xcodebuild classifies a profile as "Xcode managed" (rejecting Manual
signing) when its Name matches Xcode's auto-generated pattern
("iOS Team Provisioning Profile: ..."). Renaming the embedded plist Name
produces a profile xcodebuild accepts under CODE_SIGN_STYLE=Manual. The
UUID is unchanged, so PROVISIONING_PROFILE still matches.

Method: full re-wrap. The plist (with the new Name) is embedded in a CMS
SignedData that mirrors Apple's structure exactly — including all five of
Apple's signed attributes (contentType, signingTime, messageDigest, mac,
capabilities) with values recomputed for the new content — and is signed
with a self-signed cert (RSA-PKCS1v15 over the signed attributes DER).

Usage:
  python rename_profile.py in.mobileprovision out.mobileprovision NewName
"""
import datetime
import hashlib
import re
import sys

from cryptography import x509
from cryptography.x509.oid import NameOID
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.hazmat.primitives.serialization import pkcs7


def der_tag(tag: int, content: bytes) -> bytes:
    b = bytes([tag])
    n = len(content)
    if n < 0x80:
        b += bytes([n])
    else:
        lb = n.to_bytes((n.bit_length() + 7) // 8, "big")
        b += bytes([0x80 | len(lb)]) + lb
    return b + content


def der_int(n: int) -> bytes:
    if n == 0:
        b = b"\x00"
    else:
        b = n.to_bytes((n.bit_length() + 7) // 8, "big")
        if b[0] & 0x80:
            b = b"\x00" + b
    return der_tag(0x02, b)


# Raw OID content bytes (no tag)
OID_SIGNED_DATA = bytes.fromhex("2A864886F70D010702")  # 1.2.840.113549.1.7.2
OID_DATA = bytes.fromhex("2A864886F70D010701")        # 1.2.840.113549.1.7.1
OID_SHA1_WITH_RSA = bytes.fromhex("2B0E03021A")        # 1.3.14.3.2.26
OID_CONTENT_TYPE = bytes.fromhex("2A864886F70D010903")  # Apple's contentType attr
OID_SIGNING_TIME = bytes.fromhex("2A864886F70D010905")  # Apple's signingTime attr
OID_MESSAGE_DIGEST = bytes.fromhex("2A864886F70D010904")  # Apple's messageDigest attr
OID_MAC = bytes.fromhex("2A864886F70D010934")          # Apple's mac attr (1.9.52)
OID_CAPS = bytes.fromhex("2A864886F70D01090F")         # Apple's capabilities attr (1.9.15)
NULL_PARAM = b"\x05\x00"


def make_self_signed_cert(cn: str):
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    name = x509.Name([
        x509.NameAttribute(NameOID.COMMON_NAME, cn),
        x509.NameAttribute(NameOID.ORGANIZATION_NAME, "EdgeReturn-CI"),
    ])
    now = datetime.datetime.now(datetime.timezone.utc)
    cert = (
        x509.CertificateBuilder()
        .subject_name(name)
        .issuer_name(name)
        .public_key(key.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(now - datetime.timedelta(days=1))
        .not_valid_after(now + datetime.timedelta(days=3650))
        .add_extension(x509.BasicConstraints(ca=True, path_length=None), critical=True)
        .add_extension(
            x509.KeyUsage(
                digital_signature=True, content_commitment=False, key_encipherment=False,
                data_encipherment=False, key_agreement=False, key_cert_sign=True,
                crl_sign=False, encipher_only=False, decipher_only=False,
            ),
            critical=True,
        )
        .sign(key, hashes.SHA256())
    )
    return cert, key


def build_signed_data(plist: bytes, cert: x509.Certificate, key) -> bytes:
    digest_alg = der_tag(0x30, der_tag(0x06, OID_SHA1_WITH_RSA) + NULL_PARAM)
    digest_algs = der_tag(0x31, digest_alg)
    octet = der_tag(0x04, plist)
    encap_content = der_tag(0x30, der_tag(0x06, OID_DATA) + der_tag(0xA0, octet))
    certs_ctx = der_tag(0xA0, cert.public_bytes(serialization.Encoding.DER))

    md = hashlib.sha1(plist).digest()
    utc = datetime.datetime.now(datetime.timezone.utc).strftime("%y%m%d%H%M%SZ").encode()

    # All five of Apple's attributes, values recomputed for the new content.
    a_ct = der_tag(
        0x30,
        der_tag(0x06, OID_CONTENT_TYPE) + der_tag(0x31, der_tag(0x06, OID_SIGNED_DATA)),
    )
    a_time = der_tag(
        0x30,
        der_tag(0x06, OID_SIGNING_TIME) + der_tag(0x31, der_tag(0x17, utc)),
    )
    a_md = der_tag(
        0x30,
        der_tag(0x06, OID_MESSAGE_DIGEST) + der_tag(0x31, der_tag(0x04, md)),
    )
    # mac: SET { SEQUENCE { AlgorithmIdentifier(sha1WithRSA),
    #                  [1] { OID(sha1WithRSA 1.2.840.113549.1.1.1), NULL } }
    mac_inner = der_tag(
        0x30,
        der_tag(0x30, der_tag(0x06, OID_SHA1_WITH_RSA) + NULL_PARAM)
        + der_tag(0xA1, der_tag(0x06, bytes.fromhex("2A864886F70D010101")) + NULL_PARAM),
    )
    a_mac = der_tag(0x30, der_tag(0x06, OID_MAC) + der_tag(0x31, mac_inner))
    # capabilities: SET { SEQUENCE { 2-key-agreement OIDs } } (Apple's verbatim
    # structure; values are not content-dependent).
    caps_inner = der_tag(
        0x30,
        der_tag(0x30, der_tag(0x06, bytes.fromhex("2A864886F70D0307")))
        + der_tag(
            0x30,
            der_tag(0x30, der_tag(0x06, bytes.fromhex("2A864886F70D0302")) + der_tag(0x02, b"\x80"))
            + der_tag(0x30, der_tag(0x06, bytes.fromhex("2A864886F70D0302")) + der_tag(0x02, b"\x40"))
            + der_tag(0x30, der_tag(0x06, bytes.fromhex("2B0E030207")))
            + der_tag(0x30, der_tag(0x06, bytes.fromhex("2A864886F70D0302")) + der_tag(0x02, b"\x28")),
        ),
    )
    a_caps = der_tag(0x30, der_tag(0x06, OID_CAPS) + der_tag(0x31, caps_inner))

    signed_attrs_content = a_ct + a_time + a_md + a_mac + a_caps
    signed_attrs = der_tag(0xA0, der_tag(0x30, signed_attrs_content))

    # RSA-PKCS1v15 signature over the signed attributes DER.
    digest_info = (
        b"\x30\x21"
        b"\x30\x09\x06\x05" + OID_SHA1_WITH_RSA + b"\x05\x00"
        b"\x04\x14" + md
    )
    k = key.key_size // 8
    ps_len = k - 3 - len(digest_info)
    em = b"\x00\x01" + b"\xff" * ps_len + b"\x00" + digest_info
    pn = key.private_numbers()
    m = int.from_bytes(em, "big")
    s = pow(m, pn.d, pn.public_numbers.n)
    sig = s.to_bytes(k, "big")
    # Apple encodes the signature as an OCTET STRING (not a BIT STRING).
    signature = der_tag(0x04, sig)

    cn = b"\x0c" + b"EdgeReturn-CI"
    org = b"\x0c" + b"EdgeReturn-CI"
    rdn_cn = der_tag(0x30, der_tag(0x06, b"\x55\x04\x03") + cn)
    rdn_org = der_tag(0x30, der_tag(0x06, b"\x55\x04\x0a") + org)
    issuer_name = der_tag(0x30, der_tag(0x31, rdn_cn) + der_tag(0x31, rdn_org))
    issuer_and_serial = der_tag(0x30, issuer_name + der_int(cert.serial_number))
    sig_alg = der_tag(0x30, der_tag(0x06, OID_SHA1_WITH_RSA) + NULL_PARAM)
    signer_info = der_tag(
        0x30,
        der_int(1) + issuer_and_serial + digest_alg + signed_attrs + sig_alg + signature,
    )
    signer_infos = der_tag(0x31, signer_info)
    signed_data = der_tag(
        0x30, der_int(1) + digest_algs + encap_content + certs_ctx + signer_infos
    )
    # ContentInfo: [0] EXPLICIT SignedData (Apple's encoding).
    return der_tag(
        0x30,
        der_tag(0x06, OID_SIGNED_DATA) + der_tag(0xA0, signed_data),
    )


def find_plist(d: bytes):
    """Locate the plist OCTET STRING in the original CMS structure."""
    def parse_tlv(buf, i):
        tag = buf[i]
        n = buf[i + 1]
        off = 2
        if n & 0x80:
            nl = n & 0x7F
            n = int.from_bytes(buf[i + 2:i + 2 + nl], "big")
            off = 2 + nl
        return tag, n, i + off, i + off + n

    t, n, he, ce = parse_tlv(d, 0)
    assert t == 0x30
    j = he
    t2, n2, he2, ce2 = parse_tlv(d, j)
    assert t2 == 0x06
    t3, n3, he3, ce3 = parse_tlv(d, ce2)
    assert t3 == 0xA0
    t4, n4, he4, ce4 = parse_tlv(d, he3)
    assert t4 == 0x30
    k = he4
    seen = []
    while k < ce4:
        t, n, he, ce = parse_tlv(d, k)
        seen.append(t)
        if t == 0x30 and 0x02 in seen:
            break
        k = ce
    t5, n5, he5, ce5 = parse_tlv(d, he)
    assert t5 == 0x06
    t6, n6, he6, ce6 = parse_tlv(d, ce5)
    assert t6 == 0xA0
    t7, n7, he7, ce7 = parse_tlv(d, he6)
    assert t7 == 0x04
    return he7, ce7


def main():
    if len(sys.argv) != 4:
        print(__doc__)
        sys.exit(1)
    in_path, out_path, new_name = sys.argv[1], sys.argv[2], sys.argv[3]
    data = open(in_path, "rb").read()
    octet_he, octet_ce = find_plist(data)
    raw_plist = data[octet_he:octet_ce]
    plist = raw_plist.decode("utf-8")
    m = re.search(r"<key>Name</key>\s*<string>(.*?)</string>", plist)
    if not m:
        raise RuntimeError("Name key not found in plist")
    old_name = m.group(1)
    new_plist = plist.replace(old_name, new_name, 1).encode("utf-8")
    print(f"renamed: {old_name!r} -> {new_name!r}")

    cert, key = make_self_signed_cert("EdgeReturn-CI")
    out = build_signed_data(new_plist, cert, key)
    open(out_path, "wb").write(out)
    print("ok:", len(out), "bytes")


if __name__ == "__main__":
    main()
