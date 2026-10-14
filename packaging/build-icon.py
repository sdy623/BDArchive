"""Reproducible original BDArchive disc/tray icon. Standard library only.

Vector geometry is shared by the SVG and antialiased PNG/ICO rasterizer.
No system fonts, private files, third-party artwork or image services are used.
"""
from pathlib import Path
import math,struct,zlib,binascii
ROOT=Path(__file__).resolve().parents[1]
SIZES=(16,20,24,32,48,64,128,256)
SVG='''<svg xmlns="http://www.w3.org/2000/svg" width="256" height="256" viewBox="0 0 256 256">
<title>BDArchive</title><desc>Optical disc above an archive tray. Original BDArchive artwork.</desc>
<defs><linearGradient id="tile" x2="0" y2="1"><stop stop-color="#1b3c50"/><stop offset="1" stop-color="#0b1723"/></linearGradient></defs>
<rect x="12" y="12" width="232" height="232" rx="32" fill="url(#tile)"/>
<rect x="13" y="13" width="230" height="230" rx="31" fill="none" stroke="#426d80" stroke-width="2"/>
<circle cx="128" cy="108" r="70" fill="#102b3b" stroke="#83e5f4" stroke-width="12"/>
<circle cx="128" cy="108" r="22" fill="#0b1723" stroke="#83e5f4" stroke-width="9"/>
<path d="M72 201H184" fill="none" stroke="#d4f5fc" stroke-width="10" stroke-linecap="round"/>
<path d="M88 220H168" fill="none" stroke="#76b3c7" stroke-width="6" stroke-linecap="round"/>
</svg>'''
def rounded(x,y,lo,hi,r):
 dx=max(lo+r-x,0,x-(hi-r));dy=max(lo+r-y,0,y-(hi-r))
 return x>=lo and y>=lo and x<=hi and y<=hi and dx*dx+dy*dy<=r*r

def color(x,y):
 if not rounded(x,y,12,244,32):return None
 if not rounded(x,y,14,242,30):return (66,109,128)
 t=max(0,min(1,(y-12)/232));c=tuple(a+(b-a)*t for a,b in zip((27,60,80),(11,23,35)))
 d=math.hypot(x-128,y-108)
 if d<=76:c=(131,229,244) if d>=64 else (16,43,59)
 if d<=26.5:c=(131,229,244) if d>=17.5 else (11,23,35)
 if math.hypot(x-min(184,max(72,x)),y-201)<=5:c=(212,245,252)
 if math.hypot(x-min(168,max(88,x)),y-220)<=3:c=(118,179,199)
 return c

def chunk(kind,data):return struct.pack('>I',len(data))+kind+data+struct.pack('>I',binascii.crc32(kind+data)&0xffffffff)

def rgba(size):
 factor=8 if size<64 else 4;n=factor*factor;scale=256/size;raw=bytearray()
 for py in range(size):
  raw.append(0)
  for px in range(size):
   total=[0.,0.,0.];count=0
   for sy in range(factor):
    y=(py+(sy+.5)/factor)*scale
    for sx in range(factor):
     c=color((px+(sx+.5)/factor)*scale,y)
     if c is not None:
      count+=1
      for k in range(3):total[k]+=c[k]
   raw.extend([round(v/count) if count else 0 for v in total]+[round(255*count/n)])
 return bytes(raw)

def png(size):
 raw=rgba(size)
 return b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('>IIBBBBB',size,size,8,6,0,0,0))+chunk(b'IDAT',zlib.compress(raw,9))+chunk(b'IEND',b'')

def dib(size):
 # Small frames use a classic 32-bit DIB plus AND mask for .NET Framework/GDI.
 # Large 128/256 frames use PNG for Explorer and high-DPI shells.
 raw=rgba(size);stride=size*4+1;pixels=bytearray();mask=bytearray();mask_stride=((size+31)//32)*4
 for y in range(size-1,-1,-1):
  row=raw[y*stride+1:(y+1)*stride];bits=bytearray(mask_stride)
  for x in range(size):
   rr,gg,bb,aa=row[x*4:x*4+4];pixels.extend((bb,gg,rr,aa))
   if aa==0:bits[x//8]|=128>>(x%8)
  mask.extend(bits)
 header=struct.pack('<IiiHHIIiiII',40,size,size*2,1,32,0,len(pixels),0,0,0,0)
 return header+pixels+mask

def build():
 dest=ROOT/'assets/branding';dest.mkdir(parents=True,exist_ok=True)
 (dest/'bdarchive.svg').write_text(SVG+'\n',encoding='utf-8')
 frames=[dib(s) if s<=64 else png(s) for s in SIZES];offset=6+16*len(frames);entries=[]
 for size,data in zip(SIZES,frames):
  entries.append(struct.pack('<BBBBHHII',size%256,size%256,0,0,1,32,len(data),offset));offset+=len(data)
 (dest/'bdarchive.ico').write_bytes(struct.pack('<HHH',0,1,len(frames))+b''.join(entries)+b''.join(frames))
 print('Original SVG and 8-frame 32-bit RGBA ICO created:',dest)
if __name__=='__main__':build()
