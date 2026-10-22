"""Quick check of a muonDis_*.root file (output of makeMuonDIS.py): per incoming muon
kinematics, cross sections, DIS momentum/energy balance, soft tracks and the muon's SBT/UBT hits.

Usage (needs the FairShip dictionaries for vetoPoint):
  export PATH=/cvmfs/ship-nightlies.cern.ch/pixi/0.72.0-rattlerfs-layers-d5a7568/bin:$PATH
  pixi cvmfs /afs/cern.ch/work/j/jaweiss/FairShip_support python /afs/cern.ch/work/j/jaweiss/private/HTCondor_scripts/MuonDIS_SupStrSens/inspect_muonDis.py <muonDis_SBT_N.root>
"""

import sys
import collections
import ROOT

f = ROOT.TFile.Open(sys.argv[1])
t = f.Get("DIS")
print("entries", t.GetEntries())

muons = collections.OrderedDict()
for i, ev in enumerate(t):
    mu = ev.InMuon[0]
    key = tuple(round(mu[j], 4) for j in range(1, 8))
    d = muons.setdefault(key, {"n": 0, "xs": set(), "first": i, "ev": [], "nDIS": [], "nSoft": None, "mu": [mu[j] for j in range(14)]})
    d["n"] += 1
    d["xs"].add((int(mu[9]), round(mu[10], 6)))
    # DIS final state: momentum balance and outgoing muon
    spx = sum(p[1] for p in ev.DISParticles)
    spy = sum(p[2] for p in ev.DISParticles)
    spz = sum(p[3] for p in ev.DISParticles)
    sE = sum(p[4] for p in ev.DISParticles)
    nmu = sum(1 for p in ev.DISParticles if abs(int(p[0])) == 13)
    d["ev"].append((spx - mu[1], spy - mu[2], spz - mu[3], sE - mu[4], nmu))
    d["nDIS"].append(len(ev.DISParticles))
    if d["nSoft"] is None:
        d["nSoft"] = len(ev.SoftParticles)
        d["soft"] = [(int(p[0]), p[7]) for p in ev.SoftParticles]
        d["veto"] = [(h.GetDetectorID(), h.PdgCode(), h.GetX(), h.GetY(), h.GetZ(), h.GetEnergyLoss() * 1e3, h.GetTrackID()) for h in ev.muon_vetoPoints]
        d["ubt"] = [(h.GetDetectorID(), h.PdgCode(), h.GetX(), h.GetY(), h.GetZ(), h.GetTrackID()) for h in ev.muon_UpstreamTaggerPoints]
    else:
        assert len(ev.SoftParticles) == d["nSoft"] and len(ev.muon_vetoPoints) == len(d["veto"])

print(len(muons), "distinct muons")
for k, (key, d) in enumerate(muons.items()):
    m = d["mu"]
    p = (m[1] ** 2 + m[2] ** 2 + m[3] ** 2) ** 0.5
    print(f"\n=== muon {k}: events {d['first']}-{d['first'] + d['n'] - 1} (n={d['n']}), pid={m[0]:.0f}, p={p:.1f} GeV, w={m[8]:.4g}, xyz=({m[5]:.1f},{m[6]:.1f},{m[7]:.1f}), t={m[11]:.2f}, nDIS={m[12]:.0f}, nmuons={m[13]:.0f}")
    print("   xsec (isProton, value):", sorted(d["xs"]))
    ev = d["ev"]
    print(f"   DIS: nPart {min(d['nDIS'])}-{max(d['nDIS'])}, max|dpx,dpy,dpz| = {max(abs(e[0]) for e in ev):.3g},{max(abs(e[1]) for e in ev):.3g},{max(abs(e[2]) for e in ev):.3g}, dE range {min(e[3] for e in ev):.3f}..{max(e[3] for e in ev):.3f}, nMu per event {collections.Counter(e[4] for e in ev)}")
    print(f"   soft: {d['nSoft']} tracks, pdg {collections.Counter(s[0] for s in d['soft']).most_common(5)}, z {min((s[1] for s in d['soft']), default=0):.0f}..{max((s[1] for s in d['soft']), default=0):.0f}")
    for h in d["veto"]:
        print(f"   veto detID={h[0]:>7} pdg={h[1]:>4} trk={h[6]} xyz=({h[2]:7.1f},{h[3]:7.1f},{h[4]:7.1f}) Eloss={h[5]:.2f} MeV")
    for h in d["ubt"]:
        print(f"   UBT  detID={h[0]:>7} pdg={h[1]:>4} trk={h[5]} xyz=({h[2]:7.1f},{h[3]:7.1f},{h[4]:7.1f})")
