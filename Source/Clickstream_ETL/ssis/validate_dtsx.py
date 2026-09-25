#!/usr/bin/env python3
import argparse, re
from xml.etree import ElementTree as ET

DTS = "www.microsoft.com/SqlServer/Dts"
OBJ = f"{{{DTS}}}ObjectName"
EXEC = f"{{{DTS}}}Executable"
PC = f"{{{DTS}}}PrecedenceConstraint"
SAFE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")

ap = argparse.ArgumentParser()
ap.add_argument("package")
args = ap.parse_args()

root = ET.parse(args.package).getroot()
names = []

for e in root.iter():
    name = e.attrib.get(OBJ)
    if name is not None:
        names.append(name)
        if not SAFE.fullmatch(name):
            raise SystemExit(f"[FAIL] invalid SSIS ObjectName: {name!r}")

executables = list(root.iter(EXEC))
task_count = max(0, len(executables) - 1)
pcs = list(root.iter(PC))

if task_count != 5:
    raise SystemExit(f"[FAIL] expected 5 tasks, found {task_count}")
if len(pcs) != 4:
    raise SystemExit(f"[FAIL] expected 4 precedence constraints, found {len(pcs)}")

print("[PASS] DTSX ObjectName validation")
print("[PASS] " + ", ".join(names))
print(f"[PASS] tasks={task_count} precedence_constraints={len(pcs)}")
