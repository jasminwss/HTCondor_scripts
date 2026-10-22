"""Check that a vetoPoint detID matches its position in the geofile: prints the node found at
(x, y, z) and the global bounding box of every node whose copy number equals detID.

Usage:
  export PATH=/cvmfs/ship-nightlies.cern.ch/pixi/0.72.0-rattlerfs-layers-d5a7568/bin:$PATH
  pixi cvmfs /afs/cern.ch/work/j/jaweiss/FairShip_support python /afs/cern.ch/work/j/jaweiss/private/HTCondor_scripts/MuonDIS_SupStrSens/check_detid.py <geo_SBT_N.root> <detID> <x> <y> <z>
"""

import sys
import array
import ROOT

geo, detid, x, y, z = sys.argv[1], int(sys.argv[2]), *map(float, sys.argv[3:6])
f = ROOT.TFile.Open(geo)
gm = f.Get("FAIRGeom")
nav = gm.GetCurrentNavigator()

# node at the hit position (point may sit on a boundary: probe slightly around it)
for dz in (0.0, -0.01, 0.01):
    node = gm.FindNode(x, y, z + dz)
    print(f"FindNode z{dz:+.2f}: {gm.GetPath()}  copy={node.GetNumber()}")

# all nodes with copy number == detid: global bounding box
it = ROOT.TGeoIterator(gm.GetTopVolume())
while True:
    n = it.Next()
    if not n:
        break
    if n.GetNumber() != detid:
        continue
    path = ROOT.TString()
    it.GetPath(path)
    nav.cd(str(path))
    m = nav.GetCurrentMatrix()
    box = n.GetVolume().GetShape()
    lo, hi = [1e9] * 3, [-1e9] * 3
    for sx in (-1, 1):
        for sy in (-1, 1):
            for sz in (-1, 1):
                loc = array.array("d", [box.GetOrigin()[0] + sx * box.GetDX(), box.GetOrigin()[1] + sy * box.GetDY(), box.GetOrigin()[2] + sz * box.GetDZ()])
                glob = array.array("d", [0.0] * 3)
                m.LocalToMaster(loc, glob)
                for i in range(3):
                    lo[i], hi[i] = min(lo[i], glob[i]), max(hi[i], glob[i])
    inside = all(lo[i] - 0.01 <= v <= hi[i] + 0.01 for i, v in enumerate((x, y, z)))
    print(f"{path}  vol={n.GetVolume().GetName()}  x[{lo[0]:.1f},{hi[0]:.1f}] y[{lo[1]:.1f},{hi[1]:.1f}] z[{lo[2]:.1f},{hi[2]:.1f}]  hit inside bbox: {inside}")
