import os
import zipfile
import hashlib

def get_sha256(filepath):
    h = hashlib.sha256()
    with open(filepath, 'rb') as f:
        while chunk := f.read(65536):
            h.update(chunk)
    return h.hexdigest()

bundle_zip = 'gotrip_responsive_ui_diagnosis_bundle.zip'
checksum_file = 'SHA256SUMS_responsive_ui_diagnosis.txt'

files_to_bundle = [
    'gotrip_responsive_ui_diagnosis_report.md',
    'lib/modules/main/mainpage.dart',
    'lib/modules/main/bottomnav.dart',
    'lib/modules/place/placeDetailPage.dart',
    'test/place_detail_open_now_test.dart',
]

with zipfile.ZipFile(bundle_zip, 'w', zipfile.ZIP_DEFLATED) as zf:
    for rel_path in files_to_bundle:
        if os.path.exists(rel_path):
            norm_path = rel_path.replace('\\', '/')
            zf.write(rel_path, arcname=norm_path)
            print(f"Added {norm_path} to {bundle_zip}")

# Checksums
entries = []
for rel_path in files_to_bundle:
    if os.path.exists(rel_path):
        norm_path = rel_path.replace('\\', '/')
        h = get_sha256(rel_path)
        entries.append(f"{h}  {norm_path}")

zip_h = get_sha256(bundle_zip)
entries.append(f"{zip_h}  {bundle_zip}")

with open(checksum_file, 'w', encoding='utf-8') as f:
    f.write('\n'.join(entries) + '\n')

print(f"\nWritten {checksum_file}:")
for e in entries:
    print(e)
