import os
import zipfile
import hashlib
import subprocess

REPO_DIR = r"d:\gotrip"
OUTPUT_ZIP = os.path.join(REPO_DIR, "gotrip_shared_arrival_policy_v1_output.zip")
REPORT_FILE = os.path.join(REPO_DIR, "gotrip_shared_arrival_policy_v1_report.md")
SHA256_FILE = os.path.join(REPO_DIR, "SHA256SUMS_shared_arrival_policy_v1.txt")
COMMAND_OUTPUTS_DIR = os.path.join(REPO_DIR, "scratch", "command_outputs")
os.makedirs(COMMAND_OUTPUTS_DIR, exist_ok=True)

# 1. Capture command outputs
cmds = {
    "git_status.txt": ["git", "status", "--short"],
    "git_diff_name_only.txt": ["git", "diff", "--name-only"],
    "git_diff_stat.txt": ["git", "diff", "--stat"],
    "flutter_analyze.txt": ["flutter", "analyze", "lib/services/arrival_policy.dart", "lib/services/location_service.dart", "test/itinerary_arrival_tracking_test.dart", "test/shared_arrival_policy_test.dart"],
    "test_shared_arrival_policy.txt": ["flutter", "test", "test/shared_arrival_policy_test.dart"],
    "test_itinerary_arrival_tracking.txt": ["flutter", "test", "test/itinerary_arrival_tracking_test.dart"],
    "test_navigation_progress.txt": ["flutter", "test", "test/navigation_metric_truth_test.dart", "test/navigation_visual_progress_test.dart"],
}

for filename, cmd in cmds.items():
    out_path = os.path.join(COMMAND_OUTPUTS_DIR, filename)
    print(f"Running {' '.join(cmd)} -> {filename}")
    res = subprocess.run(cmd, cwd=REPO_DIR, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, encoding="utf-8", errors="replace", shell=True)
    with open(out_path, "w", encoding="utf-8") as f:
        f.write(res.stdout)

# 2. Build ZIP containing only created/modified files, report, and command outputs
files_to_zip = [
    ("lib/services/arrival_policy.dart", os.path.join(REPO_DIR, "lib", "services", "arrival_policy.dart")),
    ("lib/services/location_service.dart", os.path.join(REPO_DIR, "lib", "services", "location_service.dart")),
    ("lib/services/navigate_service.dart", os.path.join(REPO_DIR, "lib", "services", "navigate_service.dart")),
    ("test/itinerary_arrival_tracking_test.dart", os.path.join(REPO_DIR, "test", "itinerary_arrival_tracking_test.dart")),
    ("test/shared_arrival_policy_test.dart", os.path.join(REPO_DIR, "test", "shared_arrival_policy_test.dart")),
    ("gotrip_shared_arrival_policy_v1_report.md", REPORT_FILE),
]

for filename in os.listdir(COMMAND_OUTPUTS_DIR):
    files_to_zip.append((f"command_outputs/{filename}", os.path.join(COMMAND_OUTPUTS_DIR, filename)))

with zipfile.ZipFile(OUTPUT_ZIP, "w", zipfile.ZIP_DEFLATED) as zf:
    for arcname, fullpath in files_to_zip:
        print(f"Adding {arcname}")
        zf.write(fullpath, arcname)

print(f"Created {OUTPUT_ZIP}")

# 3. Generate SHA256 sums
def get_sha256(filepath):
    h = hashlib.sha256()
    with open(filepath, "rb") as f:
        while chunk := f.read(65536):
            h.update(chunk)
    return h.hexdigest()

checksum_entries = []
checksum_entries.append((os.path.basename(REPORT_FILE), get_sha256(REPORT_FILE)))
checksum_entries.append((os.path.basename(OUTPUT_ZIP), get_sha256(OUTPUT_ZIP)))

for arcname, fullpath in files_to_zip:
    if fullpath != REPORT_FILE:
        checksum_entries.append((arcname, get_sha256(fullpath)))

with open(SHA256_FILE, "w", encoding="utf-8") as f:
    for name, csum in checksum_entries:
        f.write(f"{csum}  {name}\n")

print(f"Created {SHA256_FILE}")
with open(SHA256_FILE, "r", encoding="utf-8") as f:
    print(f.read())
