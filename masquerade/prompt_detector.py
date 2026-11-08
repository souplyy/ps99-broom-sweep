"""Detect the recorded JUMP!/DIVE! cue shapes, without game memory access."""
from pathlib import Path
import numpy as np
from PIL import Image

ROOT=Path(__file__).resolve().parent


def color_mask(image, kind):
    a=np.asarray(image.convert('RGB'),dtype=np.int16)
    r,g,b=a[:,:,0],a[:,:,1],a[:,:,2]
    if kind=='jump':
        return (r>=205)&(g>=85)&(g<=185)&(b<=105)&(r-g>=45)
    return (r>=145)&(r<=225)&(g>=85)&(g<=190)&(b>=195)&(b-r>=25)


def load_template(kind):
    im=Image.open(ROOT/(kind+'-reference.png'))
    return color_mask(im,kind)[::2,::2]


TEMPLATES={kind:load_template(kind) for kind in ('jump','dive')}


def detect(image):
    # Recording included the Windows taskbar. Resize the game window to the
    # equivalent recorded content height, then search near the centered cue.
    frame=image.convert('RGB').resize((960,515))
    values={}
    for kind,template in TEMPLATES.items():
        mask=color_mask(frame,kind)[::2,::2]
        th,tw=template.shape
        # A cue is centered above the avatar. Search a bounded region for
        # vertical motion while excluding the permanent Dive button below.
        x_min,x_max=200,235
        y_min,y_max=57,120
        best=0.0; best_xy=None
        total=int(template.sum())
        if not total:
            raise ValueError('Empty prompt template')
        for y in range(y_min,min(y_max,mask.shape[0]-th)+1):
            for x in range(x_min,min(x_max,mask.shape[1]-tw)+1):
                patch=mask[y:y+th,x:x+tw]
                common=int(np.count_nonzero(patch & template))
                # Penalize broad solid broom regions as well as missing glyphs.
                score=2*common/(total+int(patch.sum())+1)
                if score>best:
                    best,best_xy=score,(x*2,y*2)
        values[kind]={'score':round(best,4),'position':best_xy}
    ordered=sorted(values,key=lambda k:values[k]['score'],reverse=True)
    winner=ordered[0]
    cue=winner if values[winner]['score']>=.62 and values[winner]['score']-values[ordered[1]]['score']>=.08 else None
    return cue,values
