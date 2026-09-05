import os
import zipfile
import hashlib

def get_sha256(filepath):
    h = hashlib.sha256()
    with open(filepath, 'rb') as f:
        while chunk := f.read(65536):
            h.update(chunk)
    return h.hexdigest()

files_to_zip = [
    'lib/modules/place/placeDetailPage.dart',
    'test/place_detail_open_now_test.dart',
]

zip_filename = 'gotrip_place_open_now_v1_output.zip'
checksums_filename = 'SHA256SUMS_place_open_now_v1.txt'

# Create zip file
with zipfile.ZipFile(zip_filename, 'w', zipfile.ZIP_DEFLATED) as zf:
    for rel_path in files_to_zip:
        norm_path = rel_path.replace('\\', '/')
        abs_path = os.path.join(os.getcwd(), rel_path)
        zf.write(abs_path, arcname=norm_path)
        print(f"Added {norm_path} to {zip_filename}")

# Generate checksums file
entries = []
for rel_path in files_to_zip:
    norm_path = rel_path.replace('\\', '/')
    abs_path = os.path.join(os.getcwd(), rel_path)
    h = get_sha256(abs_path)
    entries.append(f"{h}  {norm_path}")

zip_h = get_sha256(zip_filename)
entries.append(f"{zip_h}  {zip_filename}")

with open(checksums_filename, 'w', encoding='utf-8') as f:
    f.write('\n'.join(entries) + '\n')

print(f"\nWritten {checksums_filename}:")
for e in entries:
    print(e)
