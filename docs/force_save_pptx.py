"""
通过 PowerPoint COM 接口强制保存 MRD.pptx / BRD.pptx，确保 MCP 修改落地。
"""
import os
import sys
import time
import win32com.client

def force_save(file_path):
    abs_path = os.path.abspath(file_path)
    if not os.path.exists(abs_path):
        return f"[MISS] {abs_path} 不存在"
    try:
        ppt = win32com.client.Dispatch("PowerPoint.Application")
        # 已有 PowerPoint 实例
        # 直接打开
        pres = ppt.Presentations.Open(abs_path, ReadOnly=False, Untitled=False, WithWindow=False)
        time.sleep(0.5)
        pres.Save()
        time.sleep(0.5)
        pres.Close()
        size = os.path.getsize(abs_path)
        mtime = time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(os.path.getmtime(abs_path)))
        return f"[OK]  {abs_path}\n      size={size} bytes, mtime={mtime}"
    except Exception as e:
        return f"[ERR] {abs_path}\n      {e}"

if __name__ == "__main__":
    files = [
        r"d:\developer\code\aicoding\s2s\docs\BRD.pptx",
        r"d:\developer\code\aicoding\s2s\docs\MRD.pptx",
    ]
    for f in files:
        print(force_save(f))
    # 退出 PowerPoint
    try:
        ppt = win32com.client.Dispatch("PowerPoint.Application")
        ppt.Quit()
    except Exception:
        pass
