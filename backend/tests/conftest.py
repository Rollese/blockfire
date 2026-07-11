import os
import sys
import pathlib

# Make `app` and `worker` importable when running `pytest` from backend/.
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent))
