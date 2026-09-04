import os
import zipfile
import hashlib

def sha256_file(filepath):
    h = hashlib.sha256()
    with open(filepath, 'rb') as f:
        while chunk := f.read(65536):
            h.update(chunk)
    return h.hexdigest()

def main():
    repo_root = r"d:\gotrip"
    zip_name = "gotrip_place_cache_safety_v1_output.zip"
    sha_name = "SHA256SUMS_place_cache_safety_v1.txt"
    report_name = "gotrip_place_cache_safety_v1_report.md"

    zip_path = os.path.join(repo_root, zip_name)
    sha_path = os.path.join(repo_root, sha_name)
    report_path = os.path.join(repo_root, report_name)

    files_to_zip = [
        os.path.join("lib", "services", "placesAPI_service.dart"),
        os.path.join("test", "place_details_cache_safety_test.dart"),
    ]

    print(f"Packaging {zip_path} with only:")
    with zipfile.ZipFile(zip_path, 'w', compression=zipfile.ZIP_DEFLATED) as zf:
        for rel_path in files_to_zip:
            full_path = os.path.join(repo_root, rel_path)
            arcname = rel_path.replace("\\", "/")
            print(f" - {arcname}")
            zf.write(full_path, arcname=arcname)

    # Verify zip content
    with zipfile.ZipFile(zip_path, 'r') as zf:
        infolist = zf.infolist()
        print(f"Total files in zip: {len(infolist)}")
        assert len(infolist) == 2, f"Expected 2 files in zip, found {len(infolist)}"

    zip_hash = sha256_file(zip_path)
    report_hash = sha256_file(report_path)

    print(f"Report SHA256: {report_hash}")
    print(f"ZIP SHA256:    {zip_hash}")

    with open(sha_path, 'w', encoding='utf-8') as f:
        f.write(f"{report_hash}  {report_name}\n")
        f.write(f"{zip_hash}  {zip_name}\n")

    print(f"Wrote checksums to {sha_path}")

if __name__ == "__main__":
    main()
