# MuonDIS production on TRY6LiSc: how it works, what was changed, FAQ

Muon-DIS simulation for the muons of the MuonBack sample
`/eos/user/j/jaweiss/MuonBack/TRY6LiSc/11921562`.
Everything lives in `/afs/cern.ch/work/j/jaweiss/private/HTCondor_scripts/MuonDIS/`.
`README.md` in this folder is Anupama's original description. This file describes the adapted version.

---

## 1. The idea

You have a MuonBack simulation: muons flying through the detector. Muon DIS asks what happens if one of
these muons scatters hard (deep inelastic scattering) in or near the detector. So the pipeline:

1. picks out the muons that reach the detector (**stage 0**),
2. lets each of them do a DIS interaction many times with Pythia6 (**stage 1, step 1**),
3. simulates those events in the detector with Geant4 (**step 2**) and reconstructs them (**step 3**).

```
TRY6LiSc sim_*.root ──stage 0──► muonsProduction_wsoft_{SBT,Tr}.root ──stage 1──► {SBT,Tr}/job_N/{muonDis,sim,geo,params,reco}_*.root
     (condor.sub)                                                  (submitscript_{SBT,Tr}.sub)
```

## 2. Files in this folder

| File | What it is |
|---|---|
| `condor.sub` → `condor.sh` | Stage 0: one job that builds the muon lists |
| `submitscript_SBT.sub`, `submitscript_Tr.sub` → `submitscript.sh` | Stage 1: many jobs, DIS + sim + reco. Both `.sub` files use the same `.sh` and differ only in input file, output folder and muons/DIS per job |
| `test_TRY6LiSc.dag` | Small end-to-end test (stage 0, then 1 SBT and 1 Tr job) |
| `fairship_muonDIS/` | **Local, fixed copies** of FairShip's muonDIS helper scripts (see section 6) |
| `logs/` | Condor `.out`/`.err`/`.log` files |
| `test_TRY6LiSc.dag.*` | DAGMan's own bookkeeping files, created on submit |

## 3. Stage 0: picking out the muons (`condor.sh`)

One condor job runs over all ~4007 TRY6LiSc `sim_*.root` files and writes to `OUTDIR`:

| Output | Content |
|---|---|
| `muonsProduction_wsoft_SBT.root` | Muons with p > 3 GeV that hit the **SBT** |
| `muonsProduction_wsoft_Tr.root` | Muons with p > 3 GeV that hit **Tracking Station 1 but not the SBT** |
| `SelectedMuonsSBT.txt`, `SelectedMuonsTr.txt` | The same muons as readable text (see below) |
| `ntuple_SBT.log`, `ntuple_Tr.log` | Logs. The muon count is at the end |

For each muon, the `.root` file also stores its SBT/UBT hits and its "soft" secondary tracks. Stage 1 needs them.
The work is done by `make_nTuple_SBT.py` / `make_nTuple_Tr.py` (local copies, section 6).

### The symlink loop (`condor.sh`, the `for sim in ...` loop)

**Problem:** the nTuple scripts only look for a file called `ship.conical.MuonBack-TGeant4.root` in each
`job_*` folder. In TRY6LiSc it is called `sim_11921562_N.root`. Without a workaround they find nothing
and save 0 muons.

**Solution:** in the job's temporary work folder, the loop creates a symlink with the expected name for each
file. A symlink is like a desktop shortcut: nothing is copied, it only points to the real file.

```bash
for sim in "$MUONBACK_DIR"/job_*/sim_*.root; do          # go through all .../job_*/sim_*.root
    [ -f "$sim" ] || continue                             # skip if the file doesn't exist
    job=$(basename "$(dirname "$sim")")                   # .../job_0/sim_..root  ->  job_0
    mkdir -p "links/$job"                                 # create links/job_0
    ln -s "$sim" "links/$job/ship.conical.MuonBack-TGeant4.root"   # shortcut with the expected name
    n=$((n + 1))                                          # count
    if [ "$NFOLDERS" -gt 0 ] && [ "$n" -ge "$NFOLDERS" ]; then break; fi  # test only: stop after N
done
```
Result: `links/job_0/ship.conical.MuonBack-TGeant4.root -> /eos/.../job_0/sim_11921562_0.root`, etc.
The scripts are then called with `-p links`.
`NFOLDERS=0` (production default) links all files. `NFOLDERS=100` links only the first 100, for tests.
They are ordered alphabetically: `job_0, job_1, job_10, job_100, ...`.

### What is in `SelectedMuons*.txt`?

A CSV text file with one line per selected muon. Open it with any editor or `pandas.read_csv`.
**The pipeline does not use it.** It's only for looking at the muons. Example:

```
nMuons in event>3GeV,Muon PID,Momentum[GeV/c],x[m],y[m],z[m],t_muon [ns],nSoft Tracks,nSBT Hits(muon),nUBT Hits(muon),Weight_muon
1,-13.0,259.05,-0.69,-0.019,33.53,109.9,204,28,1,7.6875
```

| Column | Meaning |
|---|---|
| `nMuons in event>3GeV` | How many muons (> 3 GeV) in this MuonBack event hit the SBT |
| `Muon PID` | 13 = μ⁻, −13 = μ⁺ |
| `Momentum[GeV/c]` | Momentum at the **first** SBT hit |
| `x, y, z [m]`, `t_muon [ns]` | Position and time of that first hit |
| `nSoft Tracks` | Secondary particles the muon created along its way (e.g. δ-electrons; no nuclear interactions) |
| `nSBT Hits(muon)`, `nUBT Hits(muon)` | Number of hits of the muon itself in the SBT / Upstream Tagger |
| `Weight_muon` | MuonBack weight: how many real muons this simulated muon represents |

`SelectedMuonsTr.txt` has the same columns, but position, momentum and time belong to the first hit in
**Tracking Station 1**. These muons don't hit the SBT, so `nSBT Hits` is normally 0 there.

Rates seen in tests: about **1.5 SBT muons per MuonBack file**, but only about **1 Tr muon per 20 files**.

## 4. Stage 1: DIS + simulation + reco (`submitscript.sh`)

Many condor jobs. **N = job number** (condor's `$(Process)`, called `ProcId` in the script):
job N takes `MUONS_PER_JOB` muons starting at muon `N × MUONS_PER_JOB` and writes to `.../job_N/`.

| | muons per job | DIS per muon | events per job |
|---|---|---|---|
| SBT (`submitscript_SBT.sub`) | 10 | 100 | 1000 |
| Tr (`submitscript_Tr.sub`) | 1 | 1000 | 1000 |

(Same numbers as Anupama's original setup.) Example SBT: job 0 → muons 0–9, job 42 → muons 420–429.
`DIS_PER_MUON` is the same for every job.

Each job does three steps in a temporary folder on the worker node and copies the results to EOS
(`TAG` = `SBT_N` or `Tr_N`):

| Step | What happens | Output in `.../SBT/job_N/` |
|---|---|---|
| 1 | `makeMuonDIS.py`: Pythia6 makes the DIS interactions, half on protons and half on neutrons (so `DIS_PER_MUON` must be even) | `muonDis_SBT_N.root` |
| 2 | `run_simScript.py --MuDIS`: Geant4 simulation. Then `add_muonresponse.py` adds the incoming muon's hits | `sim_SBT_N.root`, `geo_SBT_N.root`, `params_SBT_N.root`, `simRunOutput_1.txt` |
| 3 | `ShipReco.py`: track reconstruction | `reco_SBT_N.root`, `simRunOutput_2.txt` |

### What is `muonDis.root`?

The output of step 1 and the input of step 2. `makeMuonDIS.py` always writes this name into the current
folder (hard-coded). The job copies it to EOS as `muonDis_<TAG>.root`. On a retry, step 1 is skipped and
the EOS file is copied back as `muonDis.root`, so step 2 always finds it under that name.

It contains a tree `DIS` with **one entry per DIS event** (e.g. 10 × 100 = 1000):

| Branch | Content |
|---|---|
| `InMuon` | The incoming muon, 14 numbers: PID, px/py/pz, E, x/y/z of its first SBT hit, weight, proton or neutron target (1/0), DIS cross section, time, nDIS, number of muons in the original event |
| `DISParticles` | Particles produced by Pythia6 (PID, px, py, pz, E), rotated to the muon's direction |
| `SoftParticles` | The muon's soft secondary tracks from MuonBack, with start position and time |
| `muon_vetoPoints`, `muon_UpstreamTaggerPoints` | The muon's original SBT/UBT hits from MuonBack, with TrackID set to 0 (= "track 0" in the new simulation) |

Who uses it in step 2:
1. **`run_simScript.py --MuDIS -f muonDis.root`**: FairShip's `MuDISGenerator` puts each interaction at a
   random point along the muon's path. That's between the decay-volume entrance and Tracking Station 1,
   weighted by the material there. Geant4 then simulates the outgoing particles. At the end, the cross
   section from `InMuon` is copied into a `CrossSection` branch of `sim_*.root`.
2. **`add_muonresponse.py -m muonDis.root`**: adds those `muon_vetoPoints`/`muon_UpstreamTaggerPoints` that
   lie **before** the interaction point to `sim_*.root`. Otherwise the DIS simulation only contains what
   happens after the interaction, and the incoming muon would seem to come out of nowhere.

### Built-in safety features

- **Resume:** a step is skipped if its output already exists on EOS. If `reco_*.root` exists, the job does
  nothing. Condor retries failed jobs (`max_retries = 3`) and they continue where they stopped.
  **Consequence:** to really redo a job, delete its `job_N/` folder or use a new `OUTDIR`.
- **Too many jobs is harmless:** if job N starts after the last muon, it prints "nothing to do" and exits OK,
  so rounding `NJOBS` up is safe.
- **`max_materialize = 200`:** at most 200 jobs run at the same time. The pixi binary and the helper
  scripts are on AFS, and AFS was overloaded in September 2026 when thousands of jobs read from it at once.
- **`QT_QPA_PLATFORM=offscreen`:** stops Geant4 from opening a Qt window. Without it, Geant4 aborts on
  machines without a display (`qt.qpa.xcb: could not connect to display ... *** Break *** abort`).
  The same applies when you run FairShip interactively on lxplus.

## 5. Which FairShip is used

Both shell scripts load FairShip through pixi:
```bash
FAIRSHIP=/eos/user/j/jaweiss/FairShip_latest
pixi run --frozen --manifest-path $FAIRSHIP/pixi.toml python ...
```
`pixi run` loads that FairShip's environment (ROOT, Geant4, Pythia, ...) for exactly that one command.
**To switch FairShip versions, change `FAIRSHIP=` in both `condor.sh` and `submitscript.sh`, nothing else.**

| Path | Version | Used for |
|---|---|---|
| `/eos/user/j/jaweiss/FairShip_latest` | `main` commit `520342c48` (2026-10-02, v26.09.43), unmodified, built directly on EOS | **current setting** |
| `/eos/user/j/jaweiss/FairShip` | commit `0979da44a` (2026-07-29), EOS copy of `/afs/cern.ch/work/j/jaweiss/FairShip` | the version TRY6LiSc (and TRY5) were simulated with |

Sim options in `submitscript.sh`: `--MuDIS --shieldName TRY_2026`, helium decay volume (default).
The SBT is LiquidScintillator, the default in both versions.

### How `FairShip_latest` was built

```bash
cd /eos/user/j/jaweiss
git clone https://github.com/ShipSoft/FairShip.git FairShip_latest
cd FairShip_latest
pixi run build                                      # installs the environment first, then compiles
QT_QPA_PLATFORM=offscreen pixi run ci-sim-muonback  # smoke test with a small local muon file
```
- A "connection error / broken pipe" during `pixi install` is a network glitch. Just run it again.
- Building directly on EOS works. It's slower than AFS but needs no copy step, and EOS has no quota problem.
  (The old EOS copy `/eos/user/j/jaweiss/FairShip` still has the AFS paths it was originally built with.)
- Hundreds of "data members ... will not be stored ... ClassDef" warnings during the build are normal.
- A plain `run_simScript.py` without options fails with `$EOSSHIP/...Cascade...root`. It defaults to an
  HNL signal simulation that needs an input file from `$EOSSHIP`. Use `ci-sim-muonback` as the smoke test.

## 6. Where FairShip is broken: the local copies in `fairship_muonDIS/`

FairShip's own helper scripts in `$FAIRSHIP/muonDIS/` **do not work** with current FairShip/ROOT. They
were written for an older ROOT and an older data format. So the jobs use local, fixed copies:

```
/afs/cern.ch/work/j/jaweiss/private/HTCondor_scripts/MuonDIS/fairship_muonDIS/
    make_nTuple_SBT.py   make_nTuple_Tr.py   makeMuonDIS.py   add_muonresponse.py
```

Only these 4 helper scripts are copies. **The simulation (`run_simScript.py`), the reconstruction
(`ShipReco.py`) and the geometry always come from `$FAIRSHIP`.**

### Where the scripts say "use the local copy"

The variable `SCRIPTS` in both shell scripts:
```bash
SCRIPTS=/afs/cern.ch/work/j/jaweiss/private/HTCondor_scripts/MuonDIS/fairship_muonDIS
```
| Where | Calls |
|---|---|
| `condor.sh`, `SCRIPTS=` line (~15) | defines it |
| `condor.sh` (~43, ~48) | `$SCRIPTS/make_nTuple_SBT.py`, `$SCRIPTS/make_nTuple_Tr.py` |
| `submitscript.sh`, `SCRIPTS=` line (~24) | defines it |
| `submitscript.sh` (~71) | `$SCRIPTS/makeMuonDIS.py` |
| `submitscript.sh` (~96) | `$SCRIPTS/add_muonresponse.py` |

`run_simScript.py` and `ShipReco.py` are called as `$FAIRSHIP/macro/...`, so they come from FairShip.

### The problems

The copies are taken from upstream FairShip commit `d9141f0e` (2026-08-20, the latest change to `muonDIS/`).
That commit already fixed some of the problems. The rest I fixed locally:

| # | Problem | Symptom without fix | Fixed by | Still broken in FairShip `520342c48`? |
|---|---|---|---|---|
| 1 | ROOT 6.40 removed `file.cbmsim` access; it must be `file["cbmsim"]` | nTuple scripts silently save **0 muons** (error is swallowed) | upstream | no |
| 2 | ROOT ≥ 6.32 forbids `TClonesArray[i] = obj` | `RuntimeError: You can't set items of a TClonesArray!` | upstream (`assignClonesArrayItem`) | no |
| 3 | `strawtubesPoint.GetStationNumber()` doesn't exist anymore | `AttributeError` in `make_nTuple_Tr.py` | **local**: station = `detID // 1000000`, the same formula as FairShip's `strawtubes::StrawDecode` | **yes** |
| 4 | Sim files store hits as `std::vector<vetoPoint>`, but `add_muonresponse.py` writes a `TClonesArray` | **segfault** in `TTree::Fill` | **local**: `std::vector` + `push_back` | **yes** |
| – | Temporary `TFile` in a one-liner gets garbage-collected | segfault | **local** in `submitscript.sh` (muon count check): keep the file in a variable `f = ...` | (PyROOT pitfall, not FairShip) |

The upstream version also fixes real bugs, which you get automatically through the copies:
- **DIS cross section per event was wrong.** Every event got the last (neutron) value, shifted by one event.
  Now each event has its correct proton or neutron cross section. This matters for cross-section weighting.
- **Tr nTuple mixed up hits in events with several muons.** One muon could pick up another muon's
  tracking-station hits.
- **SBT nTuple** wrote the SBT hit count into the wrong column of the printed table.
- `--nDIS` must now be a positive even number.

### Exactly which lines I changed

| File | Line(s) | Change |
|---|---|---|
| `make_nTuple_Tr.py` | 244, 309 | `hit.GetDetectorID() // 1000000` instead of `hit.GetStationNumber()` (#3, with comment) |
| `add_muonresponse.py` | ~121–155 | `r.std.vector("vetoPoint")()` / `push_back` instead of `TClonesArray` (#4, with comment). The helper import is no longer needed and was removed |

To see **all** local differences at once (`FairShip_latest/muonDIS` is exactly the upstream base):
```bash
diff -r /eos/user/j/jaweiss/FairShip_latest/muonDIS /afs/cern.ch/work/j/jaweiss/private/HTCondor_scripts/MuonDIS/fairship_muonDIS
```

**If FairShip fixes #3 and #4 one day:** set `SCRIPTS=$FAIRSHIP/muonDIS` in both shell scripts (after the
`FAIRSHIP=` line) and run the test. If it runs and saves muons, the copies are no longer needed.
To check upstream: `strawtubes/strawtubesPoint.h` has `GetStationNumber`, and `muonDIS/add_muonresponse.py`
no longer uses `TClonesArray("vetoPoint")`.

## 7. How to run

All commands from `/afs/cern.ch/work/j/jaweiss/private/HTCondor_scripts/MuonDIS`.

### Test
```bash
condor_submit_dag test_TRY6LiSc.dag
```
A DAG means "run `ntuple` first; when it succeeds, run `sbt` and `tr`". The `VARS` lines set `OUTDIR`,
`NFOLDERS`, `NJOBS`, ... for this test. Output: the `OUTDIR` in the DAG (currently `.../TRY6LiSc_test_latest`).

Submitting the same DAG again:
- Error `"test_TRY6LiSc.dag.condor.sub" already exists` → `condor_submit_dag -f test_TRY6LiSc.dag`.
  **Options go before the DAG file name.**
- First check with `condor_q` that the old DAG isn't still running.
- Because of the resume logic, jobs whose `reco_*.root` already exists in that `OUTDIR` just say
  "Nothing to do". Use a new `OUTDIR` to run everything again.
- Tr muons are rare. With few folders the Tr test job may find none and just say "nothing to do"
  (that's why `NFOLDERS` was raised from 100 to 500).

### Production
```bash
condor_submit condor.sub OUTDIR=/eos/user/j/jaweiss/MuonDIS/TRY6LiSc_latest
# wait, then read the muon counts at the end of logs/ntuple_<cluster>.out
condor_submit submitscript_SBT.sub OUTDIR=/eos/user/j/jaweiss/MuonDIS/TRY6LiSc_latest NJOBS=<SBT muons / 10, rounded up>
condor_submit submitscript_Tr.sub  OUTDIR=/eos/user/j/jaweiss/MuonDIS/TRY6LiSc_latest NJOBS=<Tr muons>
```
Without `OUTDIR=`, everything goes to `/eos/user/j/jaweiss/MuonDIS/TRY6LiSc`.
Every value written as `$(NAME:default)` in the `.sub` files can be overridden the same way
(`MUONBACK_DIR`, `OUTDIR`, `NFOLDERS`, `MUONS_PER_JOB`, `DIS_PER_MUON`). `NJOBS` has no default
(without it, 1 job is submitted). `condor_submit -dry-run out.ad <file>.sub ...` shows the resulting job
arguments without submitting anything.

### Debugging
- Logs: `logs/ntuple_<cluster>.out`, `logs/muondisSBT_<cluster>_<job>.out/.err`, `logs/muondisTr_...`.
- Hundreds of `Error in <TCling::LoadPCM>` / `TUnixSystem::FindDynamicLibrary` lines are harmless noise
  from the pixi ROOT.
- Look for `ERROR:`, `Traceback`, `segmentation violation`. A successful job ends with `SUCCESS: <dir>`.
- Run a single step by hand (on lxplus, in a scratch folder):
  ```bash
  export QT_QPA_PLATFORM=offscreen
  P="/afs/cern.ch/work/j/jaweiss/.pixi/bin/pixi run --frozen --manifest-path /eos/user/j/jaweiss/FairShip_latest/pixi.toml"
  $P python <script> ...
  ```
  Or the whole job: `bash submitscript.sh <outdir>/SBT <outdir>/muonsProduction_wsoft_SBT.root 0 1 2`.
- Timing seen on lxplus: stage 0 takes ~0.5 s per MuonBack file. One DIS job with 2 events took ~8 min,
  mostly start-up (geometry, field maps). Production jobs use `+JobFlavour = "tomorrow"`.

## 8. Things to keep in mind

- **Version mismatch:** TRY6LiSc was simulated with `0979da44a`, the DIS now runs with `520342c48`.
  The incoming muon's SBT hits added in step 2 come from the old simulation. If the SBT or shield geometry
  changed between the versions, they won't quite match the new geometry. For a fully consistent sample,
  rerun MuonBack with `FairShip_latest` too (`ProductionTRY5LiSc/submitscript3.sh`: set `FAIRSHIP=` and
  `--shieldName TRY_2026`), then set `MUONBACK_DIR` to the new sample.
- Write down which FairShip commit each sample was made with: `git -C <FairShip dir> log -1 --format='%h %cd'`.
- Never run `git pull` in a FairShip folder that running jobs use. Clone a new folder instead.
