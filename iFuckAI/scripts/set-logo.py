import argparse
from PIL import Image, ImageDraw

ap = argparse.ArgumentParser()
ap.add_argument("image")
ap.add_argument("--crop", type=int, nargs=4, metavar=("LEFT", "TOP", "RIGHT", "BOTTOM"))
ap.add_argument("--radius", type=float, default=0.2)
args = ap.parse_args()

src = Image.open(args.image).convert("RGB")
if args.crop:
    src = src.crop(tuple(args.crop))
side = min(src.size)
left, top = (src.width - side) // 2, (src.height - side) // 2
square = src.crop((left, top, left + side, top + side)).resize((1024, 1024), Image.LANCZOS)

mask = Image.new("L", (1024, 1024), 0)
ImageDraw.Draw(mask).rounded_rectangle((0, 0, 1023, 1023), radius=int(1024 * args.radius), fill=255)
edge = square.getpixel((512, 24))
icon = Image.new("RGB", (1024, 1024), edge)
icon.paste(square, mask=mask)
icon.save("iFuckAI/Assets.xcassets/AppIcon.appiconset/icon.png")

logo = square.convert("RGBA")
logo.putalpha(mask)
logo.save("iFuckAI/Assets.xcassets/Logo.imageset/logo.png")
print(f"logo and app icon updated, corner fill {edge}")
