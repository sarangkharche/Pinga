"""Create the macOS icon asset catalogue from the same rendered vector sizes."""
import json
import shutil
from pathlib import Path

root = Path('.build/Pinga.xcassets')
icons = root / 'Pinga.appiconset'
icons.mkdir(parents=True, exist_ok=True)
images = []
for points in [16, 32, 128, 256, 512]:
    for scale in [1, 2]:
        suffix = '@2x' if scale == 2 else ''
        name = f'icon_{points}x{points}{suffix}.png'
        shutil.copyfile(Path('.build/PRPing.iconset') / name, icons / name)
        images.append({'size': f'{points}x{points}', 'idiom': 'mac', 'filename': name, 'scale': f'{scale}x'})
(icons / 'Contents.json').write_text(json.dumps({'images': images, 'info': {'version': 1, 'author': 'xcode'}}))
(root / 'Contents.json').write_text(json.dumps({'info': {'version': 1, 'author': 'xcode'}}))
