"""Issue #119: the contrast of the system glass (the listening accessory and the tab bar) measured on a full-size simulator
screenshot (1206 x 2622, iPhone 17 Pro) of Collection with a phone run on (`capture.sh` takes them at half size; take a
full-size one with `-autoScreen listening -autoThenTab journal`). The background is the median pixel of each region, the
text the pixel of the strongest contrast against it: the anti-aliased cores of the letters reach the text colour.

    uv run --with pillow python3 docs/screenshots/110/measure-glass.py <screenshot.png>
"""
import sys
from PIL import Image
def lum(c):
    f=lambda x: (x/255)/12.92 if x/255<=0.04045 else (((x/255)+0.055)/1.055)**2.4
    return 0.2126*f(c[0])+0.7152*f(c[1])+0.0722*f(c[2])
def ratio(a,b):
    la,lb=lum(a),lum(b); return (max(la,lb)+.05)/(min(la,lb)+.05)
def measure(path, box, name):
    im=Image.open(path).convert("RGB").crop(box)
    px=list(im.get_flattened_data()) if hasattr(im, "get_flattened_data") else list(im.getdata())
    # background: median luminance pixel; text: pixel farthest in contrast from it
    s=sorted(px,key=lum); bg=s[len(s)//2]
    fg=max(px,key=lambda p: ratio(p,bg))
    print(f"{name}: bg #{bg[0]:02X}{bg[1]:02X}{bg[2]:02X} text #{fg[0]:02X}{fg[1]:02X}{fg[2]:02X} = {ratio(fg,bg):.2f}:1")
path=sys.argv[1]; H=2622
# full-res coordinates (1206 x 2622); accessory and tab bar from the crop at y = H-520
y0=H-520
measure(path,(190,y0+130,380,y0+180),"accessory title")
measure(path,(190,y0+185,600,y0+220),"accessory summary")
measure(path,(820,y0+150,950,y0+200),"accessory time")
measure(path,(160,y0+385,270,y0+425),"tab label Listen")
measure(path,(680,y0+385,780,y0+425),"tab label Atlas")
