#!/bin/bash
set -eo pipefail

# Step 0: collect the muons hitting the SBT / Tracking Station 1 from a MuonBack sample.
# Condor arguments (see condor.sub):
#   $1 = MUONBACK_DIR  MuonBack cluster dir containing job_*/sim_*.root
#   $2 = OUTDIR        where the muon nTuples are written
#   $3 = NFOLDERS      only use the first N job_* folders (0 = all, >0 for testing)

MUONBACK_DIR=$1
OUTDIR=$2
NFOLDERS=${3:-0}

FAIRSHIP=/eos/user/j/jaweiss/FairShip_latest   # EOS copy of the FairShip build commit 520342c48
SCRIPTS=/afs/cern.ch/work/j/jaweiss/private/HTCondor_scripts/MuonDIS/fairship_muonDIS  # muonDIS helpers, fixed for ROOT 6.40
export QT_QPA_PLATFORM=offscreen   # headless node: Geant4's Qt UI otherwise aborts with qFatal
PIXI_RUN=(/afs/cern.ch/work/j/jaweiss/.pixi/bin/pixi run --frozen --manifest-path "$FAIRSHIP/pixi.toml")
echo "Using FAIRSHIP=$FAIRSHIP (pixi env)"

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
