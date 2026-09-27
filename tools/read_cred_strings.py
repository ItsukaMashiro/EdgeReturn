#!/usr/bin/env python3
"""Read the credential's target/comment strings via advapi32 CredReadW."""
import ctypes
import ctypes.wintypes

advapi32 = ctypes.windll.advapi32

class CREDENTIAL(ctypes.Structure):
    _fields_ = [
        ("Type", ctypes.wintypes.DWORD),
        ("Target", ctypes.c_wchar_p),
        ("Comment", ctypes.c_wchar_p),
        ("LastWritten", ctypes.c_ulonglong),
        ("CredentialBlobSize", ctypes.wintypes.DWORD),
        ("CredentialBlob", ctypes.c_void_p),
        ("AttributeCount", ctypes.wintypes.DWORD),
        ("Attributes", ctypes.c_void_p),
        ("TargetAlias", ctypes.c_wchar_p),
        ("Reserved", ctypes.wintypes.DWORD),
    ]

target = "fd8e5c7795009f06f30d60190582c92c30752148a935e983288be6cfe1412dc7/key.codex-wda-provisioner"
cred = ctypes.c_void_p()
ok = advapi32.CredReadW(target, 1, 0, ctypes.byref(cred))
print("ok:", ok, "err:", ctypes.get_last_error())
if ok:
    c = ctypes.cast(cred, ctypes.POINTER(CREDENTIAL)).contents
    print("Type:", c.Type)
    print("Target:", c.Target)
    print("Comment:", c.Comment)
    print("TargetAlias:", c.TargetAlias)
    print("BlobSize:", c.CredentialBlobSize)
    if c.CredentialBlobSize:
        blob = ctypes.string_at(c.CredentialBlob, c.CredentialBlobSize)
        print("Blob head:", blob[:24].hex())
        print("Blob len:", len(blob))
