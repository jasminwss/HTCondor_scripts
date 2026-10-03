# SPDX-License-Identifier: LGPL-3.0-or-later
# SPDX-FileCopyrightText: Copyright CERN for the benefit of the SHiP Collaboration

"""rootUtils.assignClonesArrayItem from upstream FairShip (d9141f0e), which the
FairShip build used for TRY6LiSc (0979da44a) does not have yet."""


def assignClonesArrayItem(arr, index, obj) -> None:
    """Copy obj into slot `index` of a TClonesArray, expanding it as needed.

    Item assignment (arr[i] = obj) raises in ROOT >= 6.32; construct the slot
    and copy-assign into it instead. TVectorD slots are resized to match obj
    first (TVectorD::operator= requires matching sizes).
    """
    if arr.GetSize() <= index:
        arr.Expand(index + 10)
    slot = arr.ConstructedAt(index)
    if hasattr(slot, "ResizeTo"):
        slot.ResizeTo(obj)
    slot.__assign__(obj)
