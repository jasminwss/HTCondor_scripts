#!/bin/bash
set -eo pipefail

# Step 1: muon DIS for the muons collected in step 0 (condor.sh).
# Condor arguments (see submitscript_<SBT|Tr>.sub):
#   $1 = EOSDIR         output dir, one job_<ProcId>/ per job (e.g. .../MuonDIS/TRY6LiSc/SBT)
#   $2 = muonTupleFile  muonsProduction_wsoft_<SBT|Tr>.root from step 0
#   $3 = ProcId         $(Process)
#   $4 = MuonsPerJob
#   $5 = DISPerMuon     must be even (half on p, half on n)
# Steps whose output already exists in EOSDIR/job_<ProcId> are skipped, so resubmitting only redoes what is missing.

EOSDIR=$1
muonTupleFile=$2
ProcId=$3
MuonsPerJob=$4
DISPerMuon=$5

firstEvent=$((ProcId * MuonsPerJob))
TAG="$(basename "$EOSDIR")_${ProcId}"   # e.g. SBT_42
OUTPUTDIR="$EOSDIR/job_$ProcId"

FAIRSHIP=/eos/user/j/jaweiss/FairShip_latest # EOS copy of the FairShip build commit 520342c48
SCRIPTS=/afs/cern.ch/work/j/jaweiss/private/HTCondor_scripts/MuonDIS/fairship_muonDIS  # muonDIS helpers, fixed for ROOT 6.40
export QT_QPA_PLATFORM=offscreen   # headless node: Geant4's Qt UI otherwise aborts with qFatal
PIXI_RUN=(/afs/cern.ch/work/j/jaweiss/.pixi/bin/pixi run --frozen --manifest-path "$FAIRSHIP/pixi.toml")
echo "Using FAIRSHIP=$FAIRSHIP (pixi env)"

DIS_FILE="$OUTPUTDIR/muonDis_${TAG}.root"
SIM_FILE="$OUTPUTDIR/sim_${TAG}.root"
GEO_FILE="$OUTPUTDIR/geo_${TAG}.root"
PARAMS_FILE="$OUTPUTDIR/params_${TAG}.root"
REC_FILE="$OUTPUTDIR/reco_${TAG}.root"

if [ -f "$REC_FILE" ]; then
    echo "Nothing to do, $REC_FILE exists."
    exit 0
fi

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT
cd "$WORKDIR"

nMuons=$("${PIXI_RUN[@]}" python -c 'import sys, ROOT; f = ROOT.TFile.Open(sys.argv[1]); print(f["MuonAndSoftInteractions"].GetEntries())' "$muonTupleFile" 2>/dev/null | tail -1) \
    || { echo "ERROR: cannot read MuonAndSoftInteractions from $muonTupleFile"; exit 1; }
echo "$muonTupleFile: $nMuons muons, this job: muons $firstEvent - $((firstEvent + MuonsPerJob - 1)), $DISPerMuon DIS each"
if [ "$firstEvent" -ge "$nMuons" ]; then
    echo "firstEvent $firstEvent >= $nMuons muons in the nTuple, nothing to do."
    exit 0
fi

# mkdir -p can race on EOS when all jobs of a cluster create the shared parent dir at once
# ("File exists" despite -p), and EOS metadata can lag a beat; retry a few times before giving up.
for attempt in 1 2 3 4 5; do
    mkdir -p "$OUTPUTDIR" && break
    [ -d "$OUTPUTDIR" ] && break
    sleep 2
done
[ -d "$OUTPUTDIR" ] || { echo "ERROR: could not create $OUTPUTDIR"; exit 1; }

redo=false

echo
echo " Step 1/3: Generating DIS (Pythia6) for muons hitting the SBT / Tracking Station 1"
echo "=============================================================="
if [ -f "$DIS_FILE" ]; then
    echo "$DIS_FILE exists, skipping."
    cp "$DIS_FILE" muonDis.root
else
    redo=true
    "${PIXI_RUN[@]}" python "$SCRIPTS/makeMuonDIS.py" -f "$muonTupleFile" -i "$firstEvent" -n "$MuonsPerJob" --nDIS "$DISPerMuon"
    [ -f muonDis.root ] || { echo "ERROR: muonDis.root not produced"; exit 1; }
    cp muonDis.root "$DIS_FILE"
fi

echo
echo " Step 2/3: MuonDIS simulation using run_simScript.py + adding the incoming muon's SBT/UBT hits"
echo "=============================================================="
if [ "$redo" = false ] && [ -f "$SIM_FILE" ] && [ -f "$GEO_FILE" ] && [ -f "$PARAMS_FILE" ]; then
    echo "$SIM_FILE, $GEO_FILE, $PARAMS_FILE exist, skipping."
    cp "$SIM_FILE" "$GEO_FILE" .
else
    "${PIXI_RUN[@]}" python "$FAIRSHIP/macro/run_simScript.py" \
        --MuDIS \
        -f muonDis.root \
        -i 0 \
        -n $((MuonsPerJob * DISPerMuon)) \
        --shieldName TRY_2026 \
        --tag "$TAG" \
        -o . | tee simRunOutput_1.txt

    for f in "sim_${TAG}.root" "geo_${TAG}.root" "params_${TAG}.root"; do
        [ -f "$f" ] || { echo "ERROR: $f not produced"; ls -lh; exit 1; }
    done

    "${PIXI_RUN[@]}" python "$SCRIPTS/add_muonresponse.py" -m muonDis.root -f "sim_${TAG}.root"

    cp "sim_${TAG}.root"    "$SIM_FILE"
    cp "geo_${TAG}.root"    "$GEO_FILE"
    cp "params_${TAG}.root" "$PARAMS_FILE"
    cp simRunOutput_1.txt   "$OUTPUTDIR"/
fi

echo
echo " Step 3/3: Reconstruction using ShipReco.py"
echo "=============================================================="
"${PIXI_RUN[@]}" python "$FAIRSHIP/macro/ShipReco.py" \
    -f "sim_${TAG}.root" \
    -g "geo_${TAG}.root" | tee simRunOutput_2.txt

[ -f "sim_${TAG}_rec.root" ] || { echo "ERROR: reco output not produced"; ls -lh; exit 1; }
cp "sim_${TAG}_rec.root" "$REC_FILE"
cp simRunOutput_2.txt    "$OUTPUTDIR"/

echo "SUCCESS: $OUTPUTDIR"
