#!/bin/bash
set -eo pipefail

# Step 0: collect the muons hitting the SBT / Tracking Station 1 from a MuonBack sample.
# Here the "SBT" is the sensitive steel support (vetoPoint detIDs 10001-30904).
# Condor arguments (see condor.sub):
#   $1 = MUONBACK_DIR  MuonBack cluster dir containing job_*/sim_*.root
#   $2 = OUTDIR        where the muon nTuples are written
#   $3 = NFOLDERS      only use the first N job_* folders (0 = all, >0 for testing)

MUONBACK_DIR=$1
OUTDIR=$2
NFOLDERS=${3:-0}

# MUONBACK_DIR has no default: it must be the cluster folder of the MuonBack production
compgen -G "$MUONBACK_DIR/job_*" > /dev/null || {
    echo "ERROR: no job_* folders in '$MUONBACK_DIR'. Pass the cluster folder, e.g."
    echo "  condor_submit condor.sub MUONBACK_DIR=/eos/user/j/jaweiss/MuonBack/TRY6LiSc_SupStrSens/<cluster>"
    echo "Available: $(ls -d "$MUONBACK_DIR"/*/ 2>/dev/null | tr '\n' ' ')"
    exit 1
}

FAIRSHIP=/afs/cern.ch/work/j/jaweiss/FairShip_support   # branch support-structure: steel support sensitive
SCRIPTS=$FAIRSHIP/muonDIS   # muonDIS helpers incl. the fixes on branch muondis-fix
export QT_QPA_PLATFORM=offscreen   # headless node: Geant4's Qt UI otherwise aborts with qFatal
# environment served from CVMFS (pixi cvmfs), the workspace must be given explicitly in a job
export PATH=/cvmfs/ship-nightlies.cern.ch/pixi/0.72.0-rattlerfs-layers-d5a7568/bin:$PATH
PIXI_RUN=(pixi cvmfs "$FAIRSHIP")
echo "Using FAIRSHIP=$FAIRSHIP (pixi cvmfs), commit $(git -C "$FAIRSHIP" rev-parse --short HEAD)"

mkdir -p "$OUTDIR"

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT
cd "$WORKDIR"

# make_nTuple_*.py expect <path>/<folder>/ship.conical.MuonBack-TGeant4.root,
# the TRY6LiSc production names the file sim_<cluster>_<proc>.root -> symlink it.
n=0
for sim in "$MUONBACK_DIR"/job_*/sim_*.root; do
    [ -f "$sim" ] || continue
    job=$(basename "$(dirname "$sim")")
    mkdir -p "links/$job"
    ln -s "$sim" "links/$job/ship.conical.MuonBack-TGeant4.root"
    n=$((n + 1))
    if [ "$NFOLDERS" -gt 0 ] && [ "$n" -ge "$NFOLDERS" ]; then break; fi
done
echo "Linked $n MuonBack files from $MUONBACK_DIR"
[ "$n" -gt 0 ] || { echo "ERROR: no sim_*.root found in $MUONBACK_DIR/job_*"; exit 1; }

echo
echo " Muons hitting the SBT"
echo "=============================================================="
"${PIXI_RUN[@]}" python "$SCRIPTS/make_nTuple_SBT.py" -p "$WORKDIR/links" 2>&1 | grep -v "LoadPCM" | tee ntuple_SBT.log

echo
echo " Muons hitting Tracking Station 1 (and not the SBT)"
echo "=============================================================="
"${PIXI_RUN[@]}" python "$SCRIPTS/make_nTuple_Tr.py" -p "$WORKDIR/links" 2>&1 | grep -v "LoadPCM" | tee ntuple_Tr.log

cp muonsProduction_wsoft_SBT.root SelectedMuonsSBT.txt ntuple_SBT.log "$OUTDIR"/
cp muonsProduction_wsoft_Tr.root  SelectedMuonsTr.txt  ntuple_Tr.log  "$OUTDIR"/

echo
for t in SBT Tr; do
    echo "$t: $(grep -m1 'Total number of entries' ntuple_$t.log)  -> NJOBS = ceil(entries / MUONS_PER_JOB) in submitscript_$t.sub"
done
echo "SUCCESS: $OUTDIR"
