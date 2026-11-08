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
        total=int(template.sum())
        if not total:
            raise ValueError('Empty prompt template')
        y_max=min(y_max,mask.shape[0]-th)
        x_max=min(x_max,mask.shape[1]-tw)
        # Compute the same template overlap as the old nested Python loops,
        # using array operations over only the search area.
        area=mask[y_min:y_max+th,x_min:x_max+tw].astype(np.float64)
        shape=(area.shape[0]+th-1,area.shape[1]+tw-1)
        overlap=np.fft.irfft2(np.fft.rfft2(area,shape)*np.fft.rfft2(template[::-1,::-1],shape),shape)
        common=np.rint(overlap[th-1:th+y_max-y_min,tw-1:tw+x_max-x_min]).clip(min=0)
        integral=np.pad(area.cumsum(0).cumsum(1),((1,0),(1,0)))
        counts=integral[th:,tw:]-integral[:-th,tw:]-integral[th:,:-tw]+integral[:-th,:-tw]
        scores=2*common/(total+counts+1)
        iy,ix=np.unravel_index(np.argmax(scores),scores.shape)
        best=float(scores[iy,ix])
        best_xy=((x_min+int(ix))*2,(y_min+int(iy))*2) if best>0 else None
        values[kind]={'score':round(best,4),'position':best_xy}
    ordered=sorted(values,key=lambda k:values[k]['score'],reverse=True)
    winner=ordered[0]
    cue=winner if values[winner]['score']>=.62 and values[winner]['score']-values[ordered[1]]['score']>=.08 else None
    return cue,values
