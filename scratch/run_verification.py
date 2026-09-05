import os
import subprocess
import zipfile
import hashlib

REPO_DIR = r"d:\gotrip"
VERIFY_DIR = os.path.join(REPO_DIR, "scratch", "verification_outputs")
os.makedirs(VERIFY_DIR, exist_ok=True)

commands = [
    (
        "01_git_diff_location_service.txt",
        ["git", "diff", "lib/services/location_service.dart"]
    ),
    (
        "02_git_diff_navigate_service.txt",
        ["git", "diff", "lib/services/navigate_service.dart"]
    ),
    (
        "03_git_diff_itinerary_arrival_tracking_test.txt",
        ["git", "diff", "test/itinerary_arrival_tracking_test.dart"]
    ),
    (
        "04_git_diff_check.txt",
        ["git", "diff", "--check", "--", "lib/services/location_service.dart", "lib/services/navigate_service.dart", "test/itinerary_arrival_tracking_test.dart"]
    ),
    (
        "05_git_status_short.txt",
        ["git", "status", "--short"]
    ),
    (
        "06_git_diff_name_only.txt",
        ["git", "diff", "--name-only"]
    ),
    (
        "07_git_diff_stat.txt",
        ["git", "diff", "--stat"]
    ),
    (
        "08_flutter_analyze.txt",
        ["flutter", "analyze", "lib/services/arrival_policy.dart", "lib/services/location_service.dart", "lib/services/navigate_service.dart", "test/itinerary_arrival_tracking_test.dart", "test/shared_arrival_policy_test.dart"]
    ),
    (
        "09_flutter_test_shared_arrival_policy.txt",
        ["flutter", "test", "test/shared_arrival_policy_test.dart"]
    ),
    (
        "10_flutter_test_itinerary_arrival_tracking.txt",
        ["flutter", "test", "test/itinerary_arrival_tracking_test.dart"]
    ),
    (
        "11_flutter_test_navigation_tests.txt",
        ["flutter", "test", "test/navigation_metric_truth_test.dart", "test/navigation_visual_progress_test.dart"]
    ),
    (
        "12_flutter_test_full_suite.txt",
        ["flutter", "test"]
    ),
]

for out_name, cmd in commands:
    out_path = os.path.join(VERIFY_DIR, out_name)
    print(f"Executing: {' '.join(cmd)} -> {out_name}")
    res = subprocess.run(
        cmd,
        cwd=REPO_DIR,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        encoding="utf-8",
        errors="replace",
        shell=True
    )
    with open(out_path, "w", encoding="utf-8") as f:
        f.write(res.stdout)
    print(f"Completed {out_name} (exit code {res.returncode}, {len(res.stdout)} chars)")

print("All verification commands executed.")
