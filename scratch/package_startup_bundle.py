import os
import subprocess
import zipfile
import hashlib

def run_cmd(cmd, cwd=r"d:\gotrip"):
    res = subprocess.run(cmd, cwd=cwd, shell=True, capture_output=True, text=True)
    return res.stdout + res.stderr

def sha256_file(filepath):
    h = hashlib.sha256()
    with open(filepath, 'rb') as f:
        while chunk := f.read(65536):
            h.update(chunk)
    return h.hexdigest()

def extract_file_lines(src_path, start_line, end_line):
    with open(src_path, 'r', encoding='utf-8') as f:
        lines = f.readlines()
    return "".join(lines[start_line-1:end_line])

def main():
    repo_root = r"d:\gotrip"
    evidence_dir = os.path.join(repo_root, "evidence_gps_navigation_startup_diagnosis")
    os.makedirs(evidence_dir, exist_ok=True)

    print("Populating focused excerpts...")
    
    # 07 navigate_service startup excerpts
    nav_src = os.path.join(repo_root, "lib", "services", "navigate_service.dart")
    nav_excerpts = (
        "// === 1. debugGpsAgeSeconds & debugNavigationFixAgeSeconds (lines 127-137) ===\n"
        + extract_file_lines(nav_src, 127, 137)
        + "\n\n// === 2. _initWithRealLocation (lines 549-605) ===\n"
        + extract_file_lines(nav_src, 549, 605)
        + "\n\n// === 3. _subscribePositionStream & _ensureGpsHealthWatchdog (lines 1090-1188) ===\n"
        + extract_file_lines(nav_src, 1090, 1188)
        + "\n\n// === 4. _scheduleStartupGpsWatchdog (lines 1215-1259) ===\n"
        + extract_file_lines(nav_src, 1215, 1259)
        + "\n\n// === 5. isWaitingForAccurateLocation (lines 2619-2624) ===\n"
        + extract_file_lines(nav_src, 2619, 2624)
    )
    with open(os.path.join(evidence_dir, "07_navigate_service_startup_excerpts.dart"), "w", encoding="utf-8") as f:
        f.write(nav_excerpts)

    # 08 guidepage accurate location excerpt
    guide_src = os.path.join(repo_root, "lib", "modules", "place", "guidePage.dart")
    guide_excerpt = extract_file_lines(guide_src, 895, 934)
    with open(os.path.join(evidence_dir, "08_guidepage_accurate_location_excerpt.dart"), "w", encoding="utf-8") as f:
        f.write(guide_excerpt)

    # 09 debug overlay excerpt
    overlay_src = os.path.join(repo_root, "lib", "modules", "place", "navigation_debug_overlay.dart")
    overlay_excerpt = extract_file_lines(overlay_src, 140, 192)
    with open(os.path.join(evidence_dir, "09_debug_overlay_excerpt.dart"), "w", encoding="utf-8") as f:
        f.write(overlay_excerpt)

    # 10 git diff stat
    diff_stat = run_cmd("git diff --stat")
    with open(os.path.join(evidence_dir, "10_git_diff_stat.txt"), "w", encoding="utf-8") as f:
        f.write(diff_stat)

    # 11 git diff name-only
    diff_name = run_cmd("git diff --name-only")
    with open(os.path.join(evidence_dir, "11_git_diff_name_only.txt"), "w", encoding="utf-8") as f:
        f.write(diff_name)

    # Package ZIP bundle
    report_name = "gotrip_gps_navigation_startup_diagnosis_report.md"
    zip_name = "gotrip_gps_navigation_startup_diagnosis_bundle.zip"
    sha_name = "SHA256SUMS_gps_navigation_startup_diagnosis.txt"

    report_path = os.path.join(repo_root, report_name)
    zip_path = os.path.join(repo_root, zip_name)
    sha_path = os.path.join(repo_root, sha_name)

    print(f"Creating zip: {zip_path}")
    with zipfile.ZipFile(zip_path, 'w', compression=zipfile.ZIP_DEFLATED) as zf:
        zf.write(report_path, arcname=report_name)
        for root, dirs, files in os.walk(evidence_dir):
            for file in files:
                full_path = os.path.join(root, file)
                rel_path = os.path.relpath(full_path, repo_root)
                zf.write(full_path, arcname=rel_path)

    print("Zip contents:")
    with zipfile.ZipFile(zip_path, 'r') as zf:
        for info in zf.infolist():
            print(f"  {info.filename} ({info.file_size} bytes)")

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
