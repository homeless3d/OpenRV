# Encodes the jpg sequence to h264+aac / hevc / prores / h264 B-frames test movies (needs PyAV: pip install av pillow numpy).
import av, glob, os, re, numpy as np
from PIL import Image
src=os.environ.get("JPG_DIR","data/jpg")  # needs f.0001.jpg ... (see make_jpg_seq.py); output goes to data/mov/
files=sorted(glob.glob(src+"/f.*.jpg"), key=lambda p:int(re.findall(r"\.(\d+)\.jpg",p)[0]))
def mk(out,vc,pix,audio=False,fmt=None,opts=None):
    try:
        c=av.open(out,"w",format=fmt)
        s=c.add_stream(vc, rate=24); s.width=960; s.height=540; s.pix_fmt=pix
        if opts: s.options=opts
        a=None
        if audio:
            a=c.add_stream("aac", rate=48000); a.layout="stereo"
        for f in files:
            for p in s.encode(av.VideoFrame.from_image(Image.open(f).convert("RGB"))): c.mux(p)
        for p in s.encode(): c.mux(p)
        if a:
            n=len(files)*2000
            t=np.arange(n)/48000.
            x=(np.sin(2*np.pi*440*t)*0.3*32767).astype(np.int16)
            arr=np.stack([x,x]).T.reshape(1,-1)
            fr=av.AudioFrame.from_ndarray(np.ascontiguousarray(arr),format="s16",layout="stereo"); fr.sample_rate=48000
            # chunk
            from av.audio.resampler import AudioResampler
            rs=AudioResampler(format="fltp",layout="stereo",rate=48000)
            for fr2 in rs.resample(fr):
                for p in a.encode(fr2): c.mux(p)
            for p in a.encode(): c.mux(p)
        c.close(); print("ok",out)
    except Exception as e: print("FAIL",out,e)
mk("data/mov/h264_aac.mp4","libx264","yuv420p",True)
mk("data/mov/hevc.mp4","libx265","yuv420p")
mk("data/mov/prores.mov","prores_ks","yuv422p10le",opts={"profile":"3"})
mk("data/mov/h264_bframes.mp4","libx264","yuv420p",opts={"bf":"3"})
