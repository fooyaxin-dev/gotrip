import os
import hashlib
import subprocess

WORKSPACE = r"d:\gotrip"
EVIDENCE_DIR = os.path.join(WORKSPACE, "evidence")
os.makedirs(EVIDENCE_DIR, exist_ok=True)

PROTECTED_FILES = [
    r"lib/services/userPreference_service.dart",
    r"lib/modules/main/mainpage.dart",
    r"lib/models/placeModel.dart",
    r"lib/services/category_mapper.dart",
    r"lib/services/geoapify_service.dart",
    r"lib/services/geoapifyEnrichment_service.dart",
    r"lib/services/location_service.dart",
    r"lib/services/route_service.dart",
    r"lib/services/navigate_service.dart",
    r"lib/modules/place/routePreviewPage.dart",
    r"lib/modules/itinerary/itineraryGeneratePage.dart",
    r"lib/modules/itinerary/itineraryPlanPage.dart",
    r"lib/modules/itinerary/itineraryHistoryPage.dart",
    r"lib/modules/profile/journalPage.dart",
    r"lib/modules/profile/journalBookPage.dart",
    r"lib/modules/landmark/landmarkHistory.dart",
    r"pubspec.yaml",
]

ALLOWED_FILES = [
    r"lib/modules/place/detectPlacePage.dart",
    r"lib/services/nearbyPlace_service.dart",
    r"lib/services/placesAPI_service.dart",
    r"test/realtime_detect_place_test.dart",
]

def hash_file(rel_path):
    p = os.path.join(WORKSPACE, rel_path.replace("/", os.sep))
    if not os.path.isfile(p):
        return None
    h = hashlib.sha256()
    with open(p, "rb") as f:
        while chunk := f.read(65536):
            h.update(chunk)
    return h.hexdigest()

def run_cmd(cmd):
    res = subprocess.run(cmd, shell=True, cwd=WORKSPACE, capture_output=True, text=True, encoding="utf-8", errors="replace")
    return res.returncode, res.stdout, res.stderr

print("Recording pre-change git status...")
_, status_out, _ = run_cmd("git status --short")
with open(os.path.join(EVIDENCE_DIR, "pre_change_git_status.txt"), "w", encoding="utf-8") as f:
    f.write(status_out)

print("Recording pre-change hashes...")
pre_hashes = []
for f in ALLOWED_FILES + PROTECTED_FILES:
    h = hash_file(f)
    if h:
        pre_hashes.append(f"{h}  {f}")
    else:
        pre_hashes.append(f"MISSING  {f}")

with open(os.path.join(EVIDENCE_DIR, "pre_change_hashes.txt"), "w", encoding="utf-8") as f:
    f.write("\n".join(pre_hashes) + "\n")

print("Recording pre-change diff of allowed files...")
allowed_args = " ".join([f.replace("/", os.sep) for f in ALLOWED_FILES])
_, diff_out, _ = run_cmd(f"git diff -- {allowed_args}")
with open(os.path.join(EVIDENCE_DIR, "pre_change_allowed_diff.txt"), "w", encoding="utf-8") as f:
    f.write(diff_out)

print("Pre-change evidence recorded successfully.")
