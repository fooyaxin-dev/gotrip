import os
import zipfile
import hashlib

files_to_package = [
    'lib/modules/main/mainpage.dart',
    'lib/modules/place/placeDetailPage.dart',
    'test/mainpage_bottom_spacing_test.dart',
    'test/place_detail_responsive_test.dart',
]

zip_filename = 'gotrip_responsive_ui_batch1_output.zip'
checksum_filename = 'SHA256SUMS_responsive_ui_batch1.txt'

# Verify files exist
for rel_path in files_to_package:
    if not os.path.exists(rel_path):
        raise FileNotFoundError(f"Missing file: {rel_path}")

# Create zip with forward slash relative paths
with zipfile.ZipFile(zip_filename, 'w', compression=zipfile.ZIP_DEFLATED) as zf:
    for rel_path in files_to_package:
        # ensure forward slashes in zip arcname
        arcname = rel_path.replace('\\', '/')
        zf.write(rel_path, arcname=arcname)
print(f"Created {zip_filename} with {len(files_to_package)} entries.")

# Compute sha256 for all packaged files + the zip itself
sha256_lines = []
for rel_path in files_to_package:
    with open(rel_path, 'rb') as f:
        digest = hashlib.sha256(f.read()).hexdigest()
    arcname = rel_path.replace('\\', '/')
    sha256_lines.append(f"{digest}  {arcname}\n")

with open(zip_filename, 'rb') as f:
    zip_digest = hashlib.sha256(f.read()).hexdigest()
sha256_lines.append(f"{zip_digest}  {zip_filename}\n")

with open(checksum_filename, 'w', encoding='utf-8') as f:
    f.writelines(sha256_lines)
print(f"Wrote {checksum_filename}:")
for line in sha256_lines:
    print("  " + line.strip())
