# Encodes the jpg sequence to test.mp4 (H.264) and test.mov (mpeg4); output goes to data/mov/ (needs PyAV).
import av, glob, os, re, sys
from PIL import Image
src=os.environ.get("JPG_DIR","data/jpg")
files=sorted(glob.glob(src+"/f.*.jpg"), key=lambda p:int(re.findall(r"\.(\d+)\.jpg",p)[0]))
for out,codec,pix in (("data/mov/test.mp4","libx264","yuv420p"),("data/mov/test.mov","mpeg4","yuv420p")):
    c=av.open(out,"w")
    s=c.add_stream(codec, rate=24); s.width=960; s.height=540; s.pix_fmt=pix
    for f in files:
        fr=av.VideoFrame.from_image(Image.open(f).convert("RGB"))
        for p in s.encode(fr): c.mux(p)
    for p in s.encode(): c.mux(p)
    c.close(); print(out, len(files))
