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

def main():
    repo_root = r"d:\gotrip"
    evidence_dir = os.path.join(repo_root, "evidence_gps_navigation_startup_diagnosis")
    os.makedirs(evidence_dir, exist_ok=True)

    print("Collecting read-only evidence...")
    
    # 01 Git status
    status_out = run_cmd("git status --short")
    with open(os.path.join(evidence_dir, "01_git_status.txt"), "w", encoding="utf-8") as f:
        f.write(status_out)
        
    # 02 Git diff check on navigation files
    diff_out = run_cmd("git diff -- lib/services/navigate_service.dart lib/modules/place/guidePage.dart lib/modules/place/navigation_debug_overlay.dart test/navigation_metric_truth_test.dart test/navigation_visual_progress_test.dart")
    with open(os.path.join(evidence_dir, "02_git_diff_check.txt"), "w", encoding="utf-8") as f:
        f.write(diff_out)
        
    # 03 Git log forceLocationManager
    flm_log = run_cmd('git log -S "forceLocationManager" -p -- lib/services/navigate_service.dart')
    with open(os.path.join(evidence_dir, "03_git_log_force_location_manager.txt"), "w", encoding="utf-8") as f:
        f.write(flm_log)
        
    # 04 Git log recent commits
    nav_commits = run_cmd('git log -n 6 --oneline --stat lib/services/navigate_service.dart')
    with open(os.path.join(evidence_dir, "04_git_log_recent_nav_commits.txt"), "w", encoding="utf-8") as f:
        f.write(nav_commits)
        
    # 05 Flutter test summary
    test_out = run_cmd('flutter test test/navigation_metric_truth_test.dart test/navigation_visual_progress_test.dart')
    with open(os.path.join(evidence_dir, "05_flutter_test_output.txt"), "w", encoding="utf-8") as f:
        f.write(test_out)
        
    # 06 Flutter analyze summary
    analyze_out = run_cmd('flutter analyze lib/services/navigate_service.dart lib/modules/place/guidePage.dart lib/modules/place/navigation_debug_overlay.dart test/navigation_metric_truth_test.dart test/navigation_visual_progress_test.dart')
    with open(os.path.join(evidence_dir, "06_flutter_analyze_output.txt"), "w", encoding="utf-8") as f:
        f.write(analyze_out)

    print("Evidence collection complete.")

if __name__ == "__main__":
    main()
