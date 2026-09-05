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
    report_name = "gotrip_place_swr_diagnosis_report.md"
    zip_name = "gotrip_place_swr_diagnosis_bundle.zip"
    sha_name = "SHA256SUMS_place_swr_diagnosis.txt"
    evidence_dir = "evidence_place_swr_diagnosis"

    report_path = os.path.join(repo_root, report_name)
    zip_path = os.path.join(repo_root, zip_name)
    sha_path = os.path.join(repo_root, sha_name)
    evidence_path = os.path.join(repo_root, evidence_dir)

    print(f"Creating zip: {zip_path}")
    with zipfile.ZipFile(zip_path, 'w', compression=zipfile.ZIP_DEFLATED) as zf:
        # Add report
        zf.write(report_path, arcname=report_name)
        # Add evidence directory contents
        for root, dirs, files in os.walk(evidence_path):
            for file in files:
                full_path = os.path.join(root, file)
                rel_path = os.path.relpath(full_path, repo_root)
                zf.write(full_path, arcname=rel_path)

    print("Listing files in zip:")
    with zipfile.ZipFile(zip_path, 'r') as zf:
        for info in zf.infolist():
            print(f" - {info.filename} ({info.file_size} bytes)")

    report_hash = sha256_file(report_path)
    zip_hash = sha256_file(zip_path)

    print(f"Report SHA256: {report_hash}")
    print(f"Bundle SHA256: {zip_hash}")

    with open(sha_path, 'w', encoding='utf-8') as f:
        f.write(f"{report_hash}  {report_name}\n")
        f.write(f"{zip_hash}  {zip_name}\n")

    print(f"Wrote checksums to {sha_path}")

if __name__ == "__main__":
    main()
