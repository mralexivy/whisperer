#!/usr/bin/env python3
"""Export a train_pnet.py checkpoint to the WSPN weights file the app loads.
usage: export_pnet.py CHECKPOINT.pt OUT.wspn"""
import sys
from pathlib import Path
import torch
sys.path.insert(0, str(Path(__file__).resolve().parent))
from pnet import PerturbNet, export_weights  # noqa: E402

ck = torch.load(sys.argv[1], map_location="cpu")
net = PerturbNet(max_amp=ck["args"].get("max_amp", 0.05), relative=ck["args"].get("relative", 0.0), ahead=ck["args"].get("ahead", 0)); net.load_state_dict(ck["model"])
print(export_weights(net, sys.argv[2], reshape=ck["args"].get("reshape", 0.0) or 0.0))
