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


def detect(image, source_aspect=None):
    # Recording included the Windows taskbar. Resize the game window to the
    # equivalent recorded content height, then search near the centered cue.
    frame=image if image.mode == 'RGB' and image.size == (960,515) else image.convert('RGB').resize((960,515))
    aspect = source_aspect or (image.width / max(1, image.height))
    # Scaling the whole window to 960x515 stretches UI horizontally when its
    # aspect ratio differs from the recording. Scale the cue template to match.
    x_scale = max(.6, min(1.65, (960/515) / aspect))
    values={}
    for kind,template in TEMPLATES.items():
        mask=color_mask(frame,kind)[::2,::2]
        if abs(x_scale-1.0) > .025:
            template = np.asarray(Image.fromarray(template.astype(np.uint8)*255).resize(
                (max(1, round(template.shape[1]*x_scale)), template.shape[0]), Image.Resampling.NEAREST)) > 0
        th,tw=template.shape
        # A cue is centered above the avatar. Search a bounded region for
        # vertical motion while excluding the permanent Dive button below.
        center_x = (mask.shape[1]-tw)//2
        x_min,x_max=max(0,center_x-23),min(mask.shape[1]-tw,center_x+23)
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
