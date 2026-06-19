import json
def P(t,x,y,z,yaw=0): return {"type":t,"offset":[x,y,z],"yaw":yaw}
def rect(x0,z0,nx,nz):
    return {(x,z) for x in range(x0,x0+nx) for z in range(z0,z0+nz)}
def build(name, footprint, h, doors, window_every=2, roof=True):
    fp=set(footprint)
    def opens(x,z):
        d=[]
        if (x,z+1) not in fp: d.append('N')
        if (x,z-1) not in fp: d.append('S')
        if (x+1,z) not in fp: d.append('E')
        if (x-1,z) not in fp: d.append('W')
        return d
    perim=[(x,z) for (x,z) in sorted(fp) if opens(x,z)]
    pieces=[]; wi=0
    for y in range(h):
        for (x,z) in perim:
            od=opens(x,z)
            yaw = 0 if ('N' in od or 'S' in od) else 2
            t="bwall"
            if y==0 and (x,z) in doors:
                t="bwall_door"
            elif len(od)==1 and (y==0 or y==h-1) and (wi % window_every == 0):
                t="bwall_window"
            pieces.append(P(t,x,y,z,yaw)); wi+=1
    if roof:
        for (x,z) in fp:
            pieces.append(P("bfloor",x,h,z))
    json.dump({"name":name,"pieces":pieces}, open(f"buildings/{name}.json","w"), indent=2)
    c=[tuple(q["offset"]) for q in pieces]
    dup=[x for x in set(c) if c.count(x)>1]
    return f"{name}: {len(pieces)} pieces, {'DUP'+str(dup) if dup else 'ok'}"
# --- new unique templates ---
print(build("cottage",   rect(0,0,3,4), 2, {(1,0)}))                       # small cozy house
print(build("townhouse", rect(0,0,3,5), 3, {(1,0)}))                       # narrow, tall row-house
print(build("villa",     rect(0,0,6,7), 2, {(2,0)}, window_every=1))       # large house, many windows
print(build("office",    rect(0,0,5,5), 3, {(2,0)}, window_every=1))       # square commercial block
print(build("factory",   rect(0,0,8,7), 3, {(3,0),(4,0)}))                 # large industrial, bay door
print(build("hangar",    rect(0,0,11,7), 3, {(4,0),(5,0),(6,0)}))          # very wide, huge opening
print(build("shed",      rect(0,0,3,3), 2, {(1,0)}, window_every=99))      # tiny storage, no windows
# L-shaped house: a 4x4 main wing + a 3x2 side wing
print(build("lhouse",    rect(0,0,4,4) | rect(4,0,3,2), 2, {(1,0)}))
