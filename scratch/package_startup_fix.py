import os
import zipfile
import hashlib

def sha256_file(filepath):
    h = hashlib.sha256()
    with open(filepath, 'rb') as f:
        while chunk := f.read(8192):
            h.update(chunk)
    return h.hexdigest()

def main():
    root = r"D:\gotrip"
    zip_path = os.path.join(root, "gotrip_gps_navigation_startup_fix_v1_output.zip")
    sha_path = os.path.join(root, "SHA256SUMS_gps_navigation_startup_fix_v1.txt")
    report_path = os.path.join(root, "gotrip_gps_navigation_startup_fix_v1_report.md")

    files_to_zip = [
        ("lib/services/navigate_service.dart", os.path.join(root, "lib", "services", "navigate_service.dart")),
        ("test/navigation_startup_fallback_test.dart", os.path.join(root, "test", "navigation_startup_fallback_test.dart")),
        ("gotrip_gps_navigation_startup_fix_v1_report.md", report_path),
    ]

    output_dir = os.path.join(root, "scratch", "startup_fix_outputs")
    for fname in sorted(os.listdir(output_dir)):
        fpath = os.path.join(output_dir, fname)
        if os.path.isfile(fpath):
            files_to_zip.append((f"command_outputs/{fname}", fpath))

    with zipfile.ZipFile(zip_path, 'w', zipfile.ZIP_DEFLATED) as z:
        for arcname, fpath in files_to_zip:
            z.write(fpath, arcname)
            print(f"Added to zip: {arcname}")

    print(f"\nZip created at: {zip_path} (size: {os.path.getsize(zip_path)} bytes)")

    # Compute SHA256 hashes
    hash_targets = [
        ("lib/services/navigate_service.dart", os.path.join(root, "lib", "services", "navigate_service.dart")),
        ("test/navigation_startup_fallback_test.dart", os.path.join(root, "test", "navigation_startup_fallback_test.dart")),
        ("gotrip_gps_navigation_startup_fix_v1_report.md", report_path),
        ("gotrip_gps_navigation_startup_fix_v1_output.zip", zip_path),
    ]

    lines = []
    for relpath, fpath in hash_targets:
        digest = sha256_file(fpath)
        lines.append(f"{digest}  {relpath}")
        print(f"{digest}  {relpath}")

    with open(sha_path, 'w', encoding='utf-8') as f:
        f.write("\n".join(lines) + "\n")

    print(f"\nSHA256 sums written to: {sha_path}")

if __name__ == "__main__":
    main()
