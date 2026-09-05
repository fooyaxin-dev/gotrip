import os
import zipfile
import hashlib
import subprocess

REPO_DIR = r"d:\gotrip"
OUTPUT_ZIP = os.path.join(REPO_DIR, "gotrip_shared_recommendation_eligibility_v1_output.zip")
REPORT_FILE = os.path.join(REPO_DIR, "gotrip_shared_recommendation_eligibility_v1_report.md")
SHA256_FILE = os.path.join(REPO_DIR, "SHA256SUMS_shared_recommendation_eligibility_v1.txt")
VALIDATION_OUTPUTS_DIR = os.path.join(REPO_DIR, "scratch", "recommendation_eligibility_outputs")
os.makedirs(VALIDATION_OUTPUTS_DIR, exist_ok=True)

# 1. Capture validation command outputs
cmds = {
    "git_status.txt": ["git", "status", "--short"],
    "git_diff_name_only.txt": ["git", "diff", "--name-only"],
    "git_diff_stat.txt": ["git", "diff", "--stat"],
    "git_diff_patch.txt": ["git", "diff", "lib/services/for_you_recommendation_service.dart", "lib/services/nearbyPlace_service.dart", "lib/services/itinerary_service.dart"],
    "git_diff_check.txt": ["git", "diff", "--check", "--", "lib/services/recommendation_eligibility_policy.dart", "lib/services/for_you_recommendation_service.dart", "lib/services/nearbyPlace_service.dart", "lib/services/itinerary_service.dart", "test/recommendation_eligibility_policy_test.dart"],
    "flutter_analyze.txt": ["flutter", "analyze", "lib/services/recommendation_eligibility_policy.dart", "lib/services/for_you_recommendation_service.dart", "test/recommendation_eligibility_policy_test.dart"],
    "test_recommendation_eligibility_policy.txt": ["flutter", "test", "test/recommendation_eligibility_policy_test.dart"],
    "test_shared_for_you_consistency.txt": ["flutter", "test", "test/shared_for_you_consistency_test.dart", "test/realtime_detect_place_test.dart"],
    "test_itinerary_rules.txt": ["flutter", "test", "test/itinerary_rules_test.dart", "test/itinerary_task11d_regression_test.dart"],
}

for filename, cmd in cmds.items():
    out_path = os.path.join(VALIDATION_OUTPUTS_DIR, filename)
    print(f"Running {' '.join(cmd)} -> {filename}")
    res = subprocess.run(cmd, cwd=REPO_DIR, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, encoding="utf-8", errors="replace", shell=True)
    with open(out_path, "w", encoding="utf-8") as f:
        f.write(res.stdout)

# 2. Build ZIP containing only created/modified files, report, and validation outputs
files_to_zip = [
    ("lib/services/recommendation_eligibility_policy.dart", os.path.join(REPO_DIR, "lib", "services", "recommendation_eligibility_policy.dart")),
    ("lib/services/for_you_recommendation_service.dart", os.path.join(REPO_DIR, "lib", "services", "for_you_recommendation_service.dart")),
    ("lib/services/nearbyPlace_service.dart", os.path.join(REPO_DIR, "lib", "services", "nearbyPlace_service.dart")),
    ("lib/services/itinerary_service.dart", os.path.join(REPO_DIR, "lib", "services", "itinerary_service.dart")),
    ("test/recommendation_eligibility_policy_test.dart", os.path.join(REPO_DIR, "test", "recommendation_eligibility_policy_test.dart")),
    ("gotrip_shared_recommendation_eligibility_v1_report.md", REPORT_FILE),
]

for filename in os.listdir(VALIDATION_OUTPUTS_DIR):
    files_to_zip.append((f"validation_outputs/{filename}", os.path.join(VALIDATION_OUTPUTS_DIR, filename)))

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

checksum_entries = [
    (os.path.basename(REPORT_FILE), get_sha256(REPORT_FILE)),
    (os.path.basename(OUTPUT_ZIP), get_sha256(OUTPUT_ZIP)),
    ("lib/services/recommendation_eligibility_policy.dart", get_sha256(os.path.join(REPO_DIR, "lib", "services", "recommendation_eligibility_policy.dart"))),
    ("lib/services/for_you_recommendation_service.dart", get_sha256(os.path.join(REPO_DIR, "lib", "services", "for_you_recommendation_service.dart"))),
    ("lib/services/nearbyPlace_service.dart", get_sha256(os.path.join(REPO_DIR, "lib", "services", "nearbyPlace_service.dart"))),
    ("lib/services/itinerary_service.dart", get_sha256(os.path.join(REPO_DIR, "lib", "services", "itinerary_service.dart"))),
    ("test/recommendation_eligibility_policy_test.dart", get_sha256(os.path.join(REPO_DIR, "test", "recommendation_eligibility_policy_test.dart"))),
]

with open(SHA256_FILE, "w", encoding="utf-8") as f:
    for name, digest in checksum_entries:
        f.write(f"{digest}  {name}\n")

print(f"Generated {SHA256_FILE}:")
with open(SHA256_FILE, "r", encoding="utf-8") as f:
    print(f.read())
