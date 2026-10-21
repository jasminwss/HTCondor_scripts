# MuonDIS on the sensitive steel support (TRY6LiSc_SupStrSens)

Copy of `../MuonDIS_noworkaround`, changed to:
- `FAIRSHIP=/afs/cern.ch/work/j/jaweiss/FairShip_support` (branch `support-structure`: steel beams sensitive,
  detIDs 10001-30904, SBT digitisation skips them), run via `pixi cvmfs`. The git commit is printed in every log.
- muonDIS helpers from `$FAIRSHIP/muonDIS`, which already contain the two fixes from `muondis-fix`. No local copies needed.
- Output: `/eos/user/j/jaweiss/MuonDIS/TRY6LiSc_SupStrSens/`
- Input: `MUONBACK_DIR` must be the **cluster folder** of the MuonBack production
  (`.../MuonBack/TRY6LiSc_SupStrSens/<cluster>`). Default in `condor.sub`: the 30-job test, cluster `13045706`.
  For another production pass `MUONBACK_DIR=...`. With a wrong folder the job stops right away and lists the available cluster folders.

"SBT" in the file and folder names means the steel support here: `make_nTuple_SBT.py` selects muons with p > 3 GeV
that leave a `vetoPoint` in the steel. Muons hitting the steel and reaching T1 end up in the SBT sample, not in Tr.

## Run (test)

```bash
cd /afs/cern.ch/work/j/jaweiss/private/HTCondor_scripts/MuonDIS_SupStrSens

# check the MuonBack output first (all 30 jobs done?)
ls /eos/user/j/jaweiss/MuonBack/TRY6LiSc_SupStrSens/13045706/job_*/sim_*.root | wc -l

# step 0: nTuples of muons hitting the steel / T1
condor_submit condor.sub
# -> end of logs/ntuple_<cluster>.out: "SBT: Total number of entries: N" and "Tr: ..."

# step 1: DIS + sim + reco, NJOBS = ceil(N / MUONS_PER_JOB)  (defaults: SBT 10 muons x 100 DIS, Tr 1 muon x 1000 DIS)
condor_submit submitscript_SBT.sub NJOBS=<...>
condor_submit submitscript_Tr.sub  NJOBS=<...>
```

## What to check in the test

- `logs/ntuple_*.out`: `Using FAIRSHIP=.../FairShip_support (pixi cvmfs), commit ...`, both nTuple steps finish, SBT > 0 muons.
- `logs/muondisSBT_*.out`: `makeMuonDIS`, `run_simScript --MuDIS`, `add_muonresponse` and `ShipReco` all run.
- In the reco file: no steel hits among the SBT digis (`Digi_SBTHits` should be empty, there is no scintillator).
