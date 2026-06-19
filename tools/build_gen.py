import json
def P(t,x,y,z,yaw=0): return {"type":t,"offset":[x,y,z],"yaw":yaw}
def rect(x0,z0,nx,nz): return {(x,z) for x in range(x0,x0+nx) for z in range(z0,z0+nz)}
def build(name, footprint, h, doors, mat="bwall", window_every=2, roof=True, glassy=False):
    """Generic footprint building. mat = solid wall piece id; glassy => non-corner perimeter uses glass."""
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
            od=opens(x,z); yaw=0 if ('N' in od or 'S' in od) else 2
            flat=(len(od)==1)
            t=mat
            if y==0 and (x,z) in doors:
                t="bwall_door"
            elif flat and glassy:
                t="bwall_glass"
            elif flat and (wi%window_every==0):
                t="bwall_window"
            pieces.append(P(t,x,y,z,yaw)); wi+=1
    if roof:
        for (x,z) in fp: pieces.append(P("bfloor",x,h,z))
    json.dump({"name":name,"pieces":pieces}, open(f"buildings/{name}.json","w"), indent=2)
    c=[tuple(q["offset"]) for q in pieces]; dup=[x for x in set(c) if c.count(x)>1]
    return f"{name}: {len(pieces)}p {'DUP'+str(dup) if dup else 'ok'}"
