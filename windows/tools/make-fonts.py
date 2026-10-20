"""Make Windows-friendly static fonts from the Mac app's variable fonts.

WPF picks font faces more reliably when every weight is its own family, so:
  Doto (variable)          -> Doto-Black.ttf             family "Doto"
  Space Grotesk (variable) -> SpaceGrotesk-Medium.ttf    family "Space Grotesk Medium"
                              SpaceGrotesk-SemiBold.ttf  family "Space Grotesk SemiBold"
                              SpaceGrotesk-Bold.ttf      family "Space Grotesk Bold"
  Space Mono               -> copied as-is (static Regular + Bold)

All three fonts are SIL OFL 1.1 without Reserved Font Names, so instancing is allowed.
usage: python3 make-fonts.py   (needs: pip install fonttools)
"""
import os
import shutil

from fontTools.ttLib import TTFont
from fontTools.varLib.instancer import instantiateVariableFont

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, "..", "..", "Tatakan", "Resources", "Fonts")
OUT = os.path.join(HERE, "..", "Tatakan", "Assets", "Fonts")


def rename(font, family, ps, weight):
    names = font["name"]
    for rid in (1, 2, 3, 4, 6, 16, 17, 21, 22, 25):
        names.removeNames(nameID=rid)
    names.setName(family, 1, 3, 1, 0x409)
    names.setName("Regular", 2, 3, 1, 0x409)
    names.setName(ps, 3, 3, 1, 0x409)
    names.setName(family, 4, 3, 1, 0x409)
    names.setName(ps, 6, 3, 1, 0x409)
    font["OS/2"].usWeightClass = weight
    font["OS/2"].fsSelection = (font["OS/2"].fsSelection & ~0b1100001) | (1 << 6)  # REGULAR
    font["head"].macStyle = 0
    if "STAT" in font:
        del font["STAT"]


def main():
    os.makedirs(OUT, exist_ok=True)
    doto = instantiateVariableFont(TTFont(os.path.join(SRC, "Doto.ttf")), {"wght": 900, "ROND": 0})
    rename(doto, "Doto", "Doto-Black", 900)
    doto.save(os.path.join(OUT, "Doto-Black.ttf"))

    for weight, style in [(500, "Medium"), (600, "SemiBold"), (700, "Bold")]:
        f = instantiateVariableFont(TTFont(os.path.join(SRC, "SpaceGrotesk.ttf")), {"wght": weight})
        rename(f, "Space Grotesk " + style, "SpaceGrotesk-" + style, weight)
        f.save(os.path.join(OUT, f"SpaceGrotesk-{style}.ttf"))

    for name in ["SpaceMono-Regular.ttf", "SpaceMono-Bold.ttf",
                 "OFL-Doto.txt", "OFL-SpaceGrotesk.txt", "OFL-SpaceMono.txt"]:
        shutil.copy(os.path.join(SRC, name), os.path.join(OUT, name))
    print("fonts ->", os.path.normpath(OUT))


if __name__ == "__main__":
    main()
