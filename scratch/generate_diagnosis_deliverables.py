import os
import sys
import subprocess
import shutil
import zipfile
import hashlib

def run_cmd(cmd, cwd):
    print(f"Running: {cmd}")
    res = subprocess.run(cmd, cwd=cwd, shell=True, capture_output=True, text=True, encoding='utf-8', errors='replace')
    return res.stdout + "\n" + res.stderr

def sha256_file(filepath):
    h = hashlib.sha256()
    with open(filepath, 'rb') as f:
        while chunk := f.read(65536):
            h.update(chunk)
    return h.hexdigest()

def main():
    repo_root = r"d:\gotrip"
    evidence_dir = os.path.join(repo_root, "evidence_place_swr_diagnosis")
    if os.path.exists(evidence_dir):
        shutil.rmtree(evidence_dir)
    os.makedirs(evidence_dir, exist_ok=True)

    # 1. Run commands
    print("Collecting command outputs...")
    git_status = run_cmd("git status --short", repo_root)
    with open(os.path.join(evidence_dir, "01_git_status.txt"), "w", encoding="utf-8") as f:
        f.write(git_status)

    git_diff_name = run_cmd("git diff --name-only", repo_root)
    with open(os.path.join(evidence_dir, "02_git_diff_name_only.txt"), "w", encoding="utf-8") as f:
        f.write(git_diff_name)

    git_diff_stat = run_cmd("git diff --stat", repo_root)
    with open(os.path.join(evidence_dir, "03_git_diff_stat.txt"), "w", encoding="utf-8") as f:
        f.write(git_diff_stat)

    flutter_analyze = run_cmd("flutter analyze lib/services/placesAPI_service.dart lib/modules/place/placeDetailPage.dart lib/models/placeModel.dart", repo_root)
    with open(os.path.join(evidence_dir, "04_flutter_analyze.txt"), "w", encoding="utf-8") as f:
        f.write(flutter_analyze)

    flutter_test = run_cmd("flutter test test/opening_hours_evaluator_test.dart test/session_and_cache_test.dart", repo_root)
    with open(os.path.join(evidence_dir, "05_flutter_test.txt"), "w", encoding="utf-8") as f:
        f.write(flutter_test)

    # 2. Copy relevant source snapshots
    src_dir = os.path.join(evidence_dir, "source_snapshots")
    os.makedirs(src_dir, exist_ok=True)
    shutil.copy2(os.path.join(repo_root, "lib", "services", "placesAPI_service.dart"), os.path.join(src_dir, "placesAPI_service.dart"))
    shutil.copy2(os.path.join(repo_root, "lib", "modules", "place", "placeDetailPage.dart"), os.path.join(src_dir, "placeDetailPage.dart"))
    shutil.copy2(os.path.join(repo_root, "lib", "models", "placeModel.dart"), os.path.join(src_dir, "placeModel.dart"))
    shutil.copy2(os.path.join(repo_root, "lib", "services", "opening_hours_evaluator.dart"), os.path.join(src_dir, "opening_hours_evaluator.dart"))
    shutil.copy2(os.path.join(repo_root, "lib", "models", "itineraryModel.dart"), os.path.join(src_dir, "itineraryModel.dart"))

    # 3. Copy relevant test snapshots
    test_dir = os.path.join(evidence_dir, "test_snapshots")
    os.makedirs(test_dir, exist_ok=True)
    shutil.copy2(os.path.join(repo_root, "test", "opening_hours_evaluator_test.dart"), os.path.join(test_dir, "opening_hours_evaluator_test.dart"))
    shutil.copy2(os.path.join(repo_root, "test", "session_and_cache_test.dart"), os.path.join(test_dir, "session_and_cache_test.dart"))

    print("Evidence collection complete.")

if __name__ == "__main__":
    main()
