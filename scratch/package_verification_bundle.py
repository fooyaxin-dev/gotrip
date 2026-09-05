import os
import zipfile
import hashlib

REPO_DIR = r"d:\gotrip"
REPORT_FILE = os.path.join(REPO_DIR, "gotrip_shared_arrival_policy_v1_1_verification_report.md")
BUNDLE_ZIP = os.path.join(REPO_DIR, "gotrip_shared_arrival_policy_v1_1_verification_bundle.zip")
SHA256_FILE = os.path.join(REPO_DIR, "SHA256SUMS_shared_arrival_policy_v1_1_verification.txt")
VERIFY_DIR = os.path.join(REPO_DIR, "scratch", "verification_outputs")

files_to_pack = [
    ("gotrip_shared_arrival_policy_v1_1_verification_report.md", REPORT_FILE),
    ("lib/services/arrival_policy.dart", os.path.join(REPO_DIR, "lib", "services", "arrival_policy.dart")),
    ("test/shared_arrival_policy_test.dart", os.path.join(REPO_DIR, "test", "shared_arrival_policy_test.dart")),
]

# Add all verification output logs
for fname in sorted(os.listdir(VERIFY_DIR)):
    files_to_pack.append((f"verification_outputs/{fname}", os.path.join(VERIFY_DIR, fname)))

with zipfile.ZipFile(BUNDLE_ZIP, "w", zipfile.ZIP_DEFLATED) as zf:
    for arcname, fullpath in files_to_pack:
        print(f"Adding {arcname}")
        zf.write(fullpath, arcname)

print(f"Created {BUNDLE_ZIP}")

def get_sha256(filepath):
    h = hashlib.sha256()
    with open(filepath, "rb") as f:
        while chunk := f.read(65536):
            h.update(chunk)
    return h.hexdigest()

checksum_entries = []
checksum_entries.append((os.path.basename(REPORT_FILE), get_sha256(REPORT_FILE)))
checksum_entries.append((os.path.basename(BUNDLE_ZIP), get_sha256(BUNDLE_ZIP)))

for arcname, fullpath in files_to_pack:
    if fullpath != REPORT_FILE:
        checksum_entries.append((arcname, get_sha256(fullpath)))

with open(SHA256_FILE, "w", encoding="utf-8") as f:
    for name, csum in checksum_entries:
        f.write(f"{csum}  {name}\n")

print(f"Created {SHA256_FILE}")
with open(SHA256_FILE, "r", encoding="utf-8") as f:
    print(f.read())
