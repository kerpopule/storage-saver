"""Generate original geometric app artwork using only the Python standard library."""
import pathlib, struct, zlib, subprocess

def make_icon(resources):
    resources=pathlib.Path(resources);resources.mkdir(parents=True,exist_ok=True)
    iconset=resources/'StorageAtlas.iconset';iconset.mkdir(exist_ok=True)
    def chunk(t,b):return struct.pack('>I',len(b))+t+b+struct.pack('>I',zlib.crc32(t+b)&0xffffffff)
    for size in [16,32,64,128,256,512,1024]:
        raw=bytearray()
        for y in range(size):
            raw.append(0)
            for x in range(size):
                xx=(x+.5)/size;yy=(y+.5)/size
                # Rounded dark field; four asymmetric tiles form a compact storage map.
                dx=max(.20-xx,xx-.80,0);dy=max(.20-yy,yy-.80,0)
                rgba=(23,44,40,255) if dx*dx+dy*dy<=.20**2 else (0,0,0,0)
                for a,b,w,h,col in [(.23,.23,.24,.24,(217,243,139,255)),(.53,.23,.24,.38,(152,182,120,255)),(.23,.53,.24,.24,(111,150,128,255)),(.53,.67,.24,.10,(217,243,139,255))]:
                    if a<=xx<a+w and b<=yy<b+h:rgba=col
                raw.extend(rgba)
        png=b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('>IIBBBBB',size,size,8,6,0,0,0))+chunk(b'IDAT',zlib.compress(bytes(raw)))+chunk(b'IEND',b'')
        names=[]
        if size<=512:names.append(f'icon_{size}x{size}.png')
        if size>=32:names.append(f'icon_{size//2}x{size//2}@2x.png')
        for name in names:(iconset/name).write_bytes(png)
    subprocess.run(['/usr/bin/iconutil','-c','icns',str(iconset),'-o',str(resources/'StorageAtlas.icns')],check=True)
    return 'StorageAtlas.icns'
