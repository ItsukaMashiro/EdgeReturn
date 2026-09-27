#!/usr/bin/env python3
"""
Rename a provisioning profile's embedded plist Name, in place, inside the
original CMS structure.

Why: xcodebuild classifies a profile as "Xcode managed" (rejecting Manual
signing) when its Name matches Xcode's auto-generated pattern
("iOS Team Provisioning Profile: ..."). Renaming the embedded plist Name
produces a profile xcodebuild accepts under CODE_SIGN_STYLE=Manual. The
UUID is unchanged, so PROVISIONING_PROFILE still matches.

Method: surgical. The original Apple-signed CMS is kept byte-for-byte
except the plist Name value; only the length fields of the enclosing TLVs
are updated. Apple's signature/certs/attributes are untouched, so any
parser that accepted the original accepts the result.

Usage:
  python rename_profile.py in.mobileprovision out.mobileprovision NewName
"""
import re
import sys


def parse_tlv(d: bytes, i: int):
    """Parse one TLV at offset i. Returns (tag, length, header_end, content_end)."""
    tag = d[i]
    n = d[i + 1]
    off = 2
    if n & 0x80:
        nl = n & 0x7F
        n = int.from_bytes(d[i + 2:i + 2 + nl], "big")
        off = 2 + nl
    return tag, n, i + off, i + off + n


def encode_length(n: int) -> bytes:
    if n < 0x80:
        return bytes([n])
    lb = n.to_bytes((n.bit_length() + 7) // 8, "big")
    return bytes([0x80 | len(lb)]) + lb


def find_plist(d: bytes):
    """Locate the plist OCTET STRING. Returns (octet_start, header_end, content_start, content_end)."""
    # Walk: ContentInfo(0x30) -> [0](0xA0) -> SignedData(0x30) -> encapContentInfo(0x30) -> [0](0xA0) -> OCTET STRING(0x04)
    t, n, he, ce = parse_tlv(d, 0)
    assert t == 0x30, "not a ContentInfo"
    # content: OID then [0]
    j = he
    t2, n2, he2, ce2 = parse_tlv(d, j)
    assert t2 == 0x06
    t3, n3, he3, ce3 = parse_tlv(d, ce2)
    assert t3 == 0xA0
    # [0] content: the SignedData SEQUENCE (EXPLICIT)
    t4, n4, he4, ce4 = parse_tlv(d, he3)
    assert t4 == 0x30
    # walk SignedData fields to find encapContentInfo (first 0x30 after version+digestAlgs)
    k = he4
    seen = []
    while k < ce4:
        t, n, he, ce = parse_tlv(d, k)
        seen.append(t)
        if t == 0x30 and 0x02 in seen:
            # encapContentInfo candidate: SEQUENCE { OID, [0] }
            break
        k = ce
    # inside encapContentInfo: OID then [0] EXPLICIT OCTET STRING
    t5, n5, he5, ce5 = parse_tlv(d, he)
    assert t5 == 0x06
    t6, n6, he6, ce6 = parse_tlv(d, ce5)
    assert t6 == 0xA0
    t7, n7, he7, ce7 = parse_tlv(d, he6)
    assert t7 == 0x04, f"expected OCTET STRING, got {t7:#x}"
    return he6, he7, ce7  # [0] wrapper start, octet header end, octet content end


def main():
    if len(sys.argv) != 4:
        print(__doc__)
        sys.exit(1)
    in_path, out_path, new_name = sys.argv[1], sys.argv[2], sys.argv[3]
    d = bytearray(open(in_path, "rb").read())

    wrapper_start, octet_he, octet_ce = find_plist(bytes(d))
    raw_plist = bytes(d[octet_he:octet_ce])
    plist = raw_plist.decode("utf-8")
    m = re.search(r"<key>Name</key>\s*<string>(.*?)</string>", plist)
    if not m:
        raise RuntimeError("Name key not found in plist")
    old_name = m.group(1)
    new_plist = plist.replace(old_name, new_name, 1).encode("utf-8")
    # Byte-level delta: only the Name value changes, so it is the difference
    # of the two names' UTF-8 byte lengths (independent of any other
    # multi-byte content in the plist).
    delta = len(new_name.encode("utf-8")) - len(old_name.encode("utf-8"))
    assert len(new_plist) == len(raw_plist) + delta, "unexpected plist size change"
    print(f"renamed: {old_name!r} -> {new_name!r} (delta {delta:+d} bytes)")

    # Replace the plist content in place.
    d[octet_he:octet_ce] = new_plist

    # Update length fields bottom-up: octet string, [0] wrapper,
    # encapContentInfo, SignedData, [0] context, ContentInfo.
    # Each enclosing length grows by `delta`. Re-encode each header.
    def patch_length_at(start: int, old_len: int, new_len: int):
        """Replace the length bytes of the TLV at `start` (tag byte kept)."""
        old_enc = encode_length(old_len)
        new_enc = encode_length(new_len)
        # The length field starts at start+1 and spans len(old_enc) bytes.
        d[start + 1:start + 1 + len(old_enc)] = new_enc
        return len(new_enc) - len(old_enc)  # header size change

    # 1. OCTET STRING (at octet header start = octet_he - len(encode_length(old_octet_len)))
    old_octet_len = octet_ce - octet_he
    # find the octet tag position: it's the TLV we parsed; header starts where?
    # Re-derive from the [0] wrapper content start.
    # Simpler: recompute positions from the modified buffer by re-walking.
    # (Content before the octet is unchanged, so walk again.)
    t, n, he, ce = parse_tlv(bytes(d), 0)
    j = he
    t2, n2, he2, ce2 = parse_tlv(bytes(d), j)
    t3, n3, he3, ce3 = parse_tlv(bytes(d), ce2)
    t4, n4, he4, ce4 = parse_tlv(bytes(d), he3)
    k = he4
    encap_start = None
    seen = []
    while k < ce4:
        t, n, he, ce = parse_tlv(bytes(d), k)
        seen.append(t)
        if t == 0x30 and 0x02 in seen:
            encap_start = k
            break
        k = ce
    t5, n5, he5, ce5 = parse_tlv(bytes(d), encap_start)
    # The inner OID starts at the encap header end (he5), not at ce5
    # (which is the end of the whole encap TLV).
    t5b, n5b, he5b, ce5b = parse_tlv(bytes(d), he5)
    t6, n6, he6, ce6 = parse_tlv(bytes(d), ce5b)
    t7, n7, he7, ce7 = parse_tlv(bytes(d), he6)
    octet_tag_pos = he6  # the [0] wrapper's content start == octet TLV start
    # patch octet length
    patch_length_at(octet_tag_pos, n7, n7 + delta)
    # patch [0] wrapper (at ce5b — after the inner OID)
    patch_length_at(ce5b, n6, n6 + delta)
    # patch encapContentInfo (at encap_start)
    patch_length_at(encap_start, n5, n5 + delta)
    # patch SignedData (at he3)
    patch_length_at(he3, n4, n4 + delta)
    # patch [0] context (at ce2)
    patch_length_at(ce2, n3, n3 + delta)
    # patch ContentInfo (at 0)
    patch_length_at(0, n, n + delta)

    open(out_path, "wb").write(bytes(d))
    print("ok:", len(d), "bytes written")


if __name__ == "__main__":
    main()
