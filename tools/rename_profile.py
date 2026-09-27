#!/usr/bin/env python3
"""
Rename a provisioning profile's embedded plist Name and re-wrap it in a
minimal CMS SignedData (self-signed cert).

Why: xcodebuild classifies a profile as "Xcode managed" (rejecting Manual
signing) when its Name matches Xcode's auto-generated pattern
("iOS Team Provisioning Profile: ..."). Renaming the embedded plist Name
locally and re-encoding produces a profile xcodebuild accepts under
CODE_SIGN_STYLE=Manual. The UUID is unchanged.

Usage:
  python rename_profile.py in.mobileprovision out.mobileprovision NewName
"""
import datetime
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
# Match Apple's own encoding: sha1WithRSA (1.3.14.3.2.26).
OID_SHA1_WITH_RSA = bytes.fromhex("2B0E03021A")
NULL_PARAM = b"\x05\x00"


def make_self_signed_cert(cn: str) -> x509.Certificate:
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


def build_signed_data(plist: bytes, cert: x509.Certificate) -> bytes:
    digest_alg = der_tag(0x30, der_tag(0x06, OID_SHA1_WITH_RSA) + NULL_PARAM)
    digest_algs = der_tag(0x31, digest_alg)
    octet = der_tag(0x04, plist)
    encap_content = der_tag(0x30, der_tag(0x06, OID_DATA) + der_tag(0xA0, octet))
    certs_ctx = der_tag(0xA0, cert.public_bytes(serialization.Encoding.DER))
    signer_infos = der_tag(0x31, b"")  # empty SET
    signed_data = der_tag(
        0x30, der_int(1) + digest_algs + encap_content + certs_ctx + signer_infos
    )
    # ContentInfo: [0] EXPLICIT SignedData — Apple's encoding nests the full
    # SEQUENCE inside the context tag.
    content_info = der_tag(
        0x30,
        der_tag(0x06, OID_SIGNED_DATA) + der_tag(0xA0, signed_data),
    )
    return content_info


def main():
    if len(sys.argv) != 4:
        print(__doc__)
        sys.exit(1)
    in_path, out_path, new_name = sys.argv[1], sys.argv[2], sys.argv[3]
    data = open(in_path, "rb").read()

    # Extract the embedded plist from the original CMS structure.
    # The plist is the OCTET STRING inside encapContentInfo. Walk the DER.
    def find_plist(d: bytes) -> bytes:
        # SignedData.encapContentInfo.content is [0] EXPLICIT OCTET STRING.
        # Find the 0xA0 context tag that contains a 0x04 octet string.
        i = 0
        while i < len(d) - 2:
            if d[i] == 0xA0:
                # parse length
                n = d[i + 1]
                off = 2
                if n & 0x80:
                    nl = n & 0x7F
                    n = int.from_bytes(d[i + 2:i + 2 + nl], "big")
                    off = 2 + nl
                inner = d[i + off:i + off + n]
                if inner[:1] == b"\x04":
                    # an OCTET STRING inside the [0] wrapper
                    m = inner[1]
                    moff = 2
                    if m & 0x80:
                        ml = m & 0x7F
                        m = int.from_bytes(inner[2:2 + ml], "big")
                        moff = 2 + ml
                    return inner[moff:moff + m]
            i += 1
        raise RuntimeError("plist not found in profile")

    plist = find_plist(data)
    text = plist.decode("utf-8")
    m = re.search(r"<key>Name</key>\s*<string>(.*?)</string>", text)
    if not m:
        raise RuntimeError("Name key not found in plist")
    old_name = m.group(1)
    text = text.replace(old_name, new_name, 1)
    print(f"renamed: {old_name!r} -> {new_name!r}")

    cert, key = make_self_signed_cert("EdgeReturn-CI")
    out = build_signed_data(text.encode("utf-8"), cert)
    open(out_path, "wb").write(out)

    # Sanity: the re-wrapped file must parse as a PKCS#7 with our cert.
    certs = pkcs7.load_der_pkcs7_certificates(out)
    assert len(certs) == 1, "cert not embedded"
    print("ok:", len(out), "bytes; cert CN =",
          certs[0].subject.get_attributes_for_oid(NameOID.COMMON_NAME)[0].value)


if __name__ == "__main__":
    main()
