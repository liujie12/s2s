"""bitmap-to-svg self-test. Bypasses MCP transport, calls tool functions directly.

Focus: (1) holes preserved as sub-paths, (2) bezier output not polyline,
(3) canvas normalization lands inside safe area, (4) errors are actionable.
Labels are ASCII to survive the terminal's codepage.
"""

import importlib.util
import json
import os
import re
import sys
import tempfile

SERVER = r"D:\ai_project\mcp\bitmap-to-svg\server.py"
IMG_HEAD = r"d:\developer\code\aicoding\s2s\prototype-figma\assets\source\ip-4b-head-clean.png"
IMG_RAW = r"d:\developer\code\aicoding\s2s\prototype-figma\assets\source\ip-4b-source.png"

spec = importlib.util.spec_from_file_location("bts", SERVER)
bts = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bts)


def raw(name):
    """Unwrap FastMCP's FunctionTool back to the plain python function."""
    obj = getattr(bts, name)
    return getattr(obj, "fn", obj)


inspect_bitmap = raw("inspect_bitmap")
trace = raw("trace_bitmap_to_svg")
preprocess = raw("preprocess_bitmap")

passed, failed = [], []


def check(label, condition, detail=""):
    (passed if condition else failed).append(f"{label} | {detail}".strip())
    print(("PASS  " if condition else "FAIL  ") + label + (f"  [{detail}]" if detail else ""))


# --- 1. inspect: one shape, one hole (the eye dot) ---
rep = json.loads(inspect_bitmap(IMG_HEAD))
check("inspect no error", "error" not in rep, str(rep.get("error", "")))
check("inspect shape_count==1", rep.get("shape_count") == 1, f"got {rep.get('shape_count')}")
check("inspect hole_count==1 (eye)", rep.get("hole_count") == 1, f"got {rep.get('hole_count')}")
# pure binary input -> Otsu legitimately returns 0; only assert it is in range
check("inspect otsu in 0..254", 0 <= rep.get("used_threshold", -1) <= 254, f"th={rep.get('used_threshold')}")
check("inspect fg ratio sane", 0.05 < rep.get("foreground_ratio", 0) < 0.9, f"ratio={rep.get('foreground_ratio')}")

# --- 2. trace: hole must survive ---
out_svg = os.path.join(tempfile.gettempdir(), "bts-selftest.svg")
res = json.loads(trace(IMG_HEAD, out_svg, canvas_size=1024, safe_area_ratio=0.83))
check("trace ok", res.get("ok") is True, str(res.get("error", "")))
check("trace path_count==1", res.get("path_count") == 1, f"got {res.get('path_count')}")
check("trace hole_count==1", res.get("hole_count") == 1, f"got {res.get('hole_count')}")

svg = res.get("svg", "")
d_attr = re.search(r'd="([^"]+)"', svg).group(1)
check("bezier C present", d_attr.count("C") > 20, f"C count={d_attr.count('C')}")
check("no polyline L cmds", "L" not in d_attr)
check("evenodd fill-rule", 'fill-rule="evenodd"' in svg)
check("2 sub-paths in one d", d_attr.count("M") == 2, f"M count={d_attr.count('M')}")
check("svg file written", os.path.isfile(out_svg) and os.path.getsize(out_svg) > 500,
      f"{os.path.getsize(out_svg) if os.path.isfile(out_svg) else 0} bytes")

# --- 3. normalization: inside canvas, long edge ~= safe area ---
coords = [float(v) for v in re.findall(r"-?\d+\.?\d*", d_attr)]
xs, ys = coords[0::2], coords[1::2]
check("coords within 0..1024", min(coords) >= -1 and max(coords) <= 1025,
      f"range=[{min(coords):.1f},{max(coords):.1f}]")
span = max(max(xs) - min(xs), max(ys) - min(ys))
check("long edge ~= 850", 830 <= span <= 870, f"span={span:.1f}")
# centered: gaps on opposing sides should be near-equal
gap_l, gap_r = min(xs), 1024 - max(xs)
check("horizontally centered", abs(gap_l - gap_r) < 3, f"L={gap_l:.1f} R={gap_r:.1f}")

# --- 4. reverse checks: bad input must fail loudly with guidance ---
bad = json.loads(trace("D:/nope/missing.png"))
check("missing file errors", bad.get("ok") is False and "不存在" in bad.get("error", ""))

bad2 = json.loads(trace(IMG_HEAD, threshold=255, invert=True, min_area=999999))
check("no-shape error suggests inspect", bad2.get("ok") is False and "inspect_bitmap" in bad2.get("error", ""))

bad3 = json.loads(trace(IMG_HEAD, safe_area_ratio=1.5))
check("safe_area_ratio guarded", bad3.get("ok") is False and "safe_area_ratio" in bad3.get("error", ""))

bad3b = json.loads(trace(IMG_HEAD, precision=0))
check("precision guarded", bad3b.get("ok") is False and "precision" in bad3b.get("error", ""))

# --- 5. preprocess: wash the subject out of the busy source ---
pre_out = os.path.join(tempfile.gettempdir(), "bts-pre.png")
pre = json.loads(preprocess(IMG_RAW, pre_out, crop="290,255,470,500", keep_component_at="235,250"))
check("preprocess ok", pre.get("ok") is True, str(pre.get("error", "")))
if pre.get("ok"):
    rep2 = json.loads(inspect_bitmap(pre["output_png_path"]))
    check("outer rings stripped -> 1 shape", rep2.get("shape_count") == 1, f"got {rep2.get('shape_count')}")
    check("hole survives preprocess", rep2.get("hole_count") == 1, f"got {rep2.get('hole_count')}")

bad4 = json.loads(preprocess(IMG_RAW, pre_out, crop="0,0,99999,99999"))
check("crop bounds guarded", bad4.get("ok") is False and "超出图像范围" in bad4.get("error", ""))

bad4b = json.loads(preprocess(IMG_RAW, pre_out, crop="not,a,rect"))
check("crop format guarded", bad4b.get("ok") is False and "crop" in bad4b.get("error", ""))

# seed on genuine background: use the clean head image, whose corner is white
bad5 = json.loads(preprocess(IMG_HEAD, pre_out, keep_component_at="2,2"))
check("seed-on-background suggests inspect",
      bad5.get("ok") is False and "inspect_bitmap" in bad5.get("error", ""),
      bad5.get("error", "")[:60])

bad5b = json.loads(preprocess(IMG_HEAD, pre_out, keep_component_at="99999,99999"))
check("seed bounds guarded", bad5b.get("ok") is False and "超出范围" in bad5b.get("error", ""))

print(f"\n{len(passed)} passed, {len(failed)} failed")
if failed:
    for f in failed:
        print("  FAILED:", f)
    sys.exit(1)
print("SVG written to:", out_svg)
