"""Independent complete-document PNG row oracle. No matcher or CG geometry."""
import json
import pathlib
import sys
import numpy as np
from PIL import Image

folder = pathlib.Path(sys.argv[1])
data = json.loads((folder / 'deskcapture-quality-diagnostic.json').read_text())
start = json.loads((folder / 'case-at-start.json').read_text())
if (start.get('strictSourceRGBAErrorAllowed') != 0 or start.get('originalDisplayRGBErrorAllowed') != 2
        or data.get('scope') != 'whole-page-scroll-debug-only'
        or data.get('executableSHA256') != start.get('binarySHA256')):
    raise ValueError('Frozen measurement policy, scope or executable identity mismatch')
results = []
for row in data['cases']:
    name = row.get('direction', row['case'])
    try:
        if not row.get('success') or not row.get('startedAtBoundary') or not row.get('reachedOppositeBoundary'):
            raise ValueError('Successful complete-boundary session required')
        images, positions = [], []
        leading, trailing, scale = row['leadingPixels'], row['trailingPixels'], row['scale']
        for number in range(1, row['frames'] + 1):
            prefix = f'whole-page-{name}'
            images.append(Image.open(folder / 'normalized-sources' / f'{prefix}-source-{number}.png').convert('RGBA'))
            geometry = json.loads((folder / 'artifacts' / f'{prefix}-geometry-{number}.json').read_text())
            positions.append(round(geometry['currentY'] * scale))
        width, height = images[0].size
        body_height = height - leading - trailing
        reverse = name == 'reverse'
        steps = [a-b if reverse else b-a for a, b in zip(positions, positions[1:])]
        if not steps or any(step <= 0 or step >= body_height for step in steps):
            raise ValueError('Accepted source positions do not overlap monotonically')
        if min(positions) != 0 or max(positions) + body_height != round(2500 * scale):
            raise ValueError('Independent frame positions do not cover the whole original document')
        expected = Image.new('RGBA', (width, height + sum(steps)))
        expected.paste(images[0].crop((0, 0, width, leading)), (0, 0))
        expected.paste(images[0].crop((0, height-trailing, width, height)), (0, expected.height-trailing))
        cursor = leading + (sum(steps) if reverse else 0)
        expected.paste(images[0].crop((0, leading, width, height-trailing)), (0, cursor))
        if not reverse:
            cursor += body_height
        for image, step in zip(images[1:], steps):
            if image.size != (width, height):
                raise ValueError('Source viewport dimensions changed')
            if reverse:
                cursor -= step
                strip = image.crop((0, leading, width, leading+step))
            else:
                strip = image.crop((0, height-trailing-step, width, height-trailing))
            expected.paste(strip, (0, cursor))
            if not reverse:
                cursor += step
        actual = Image.open(folder / 'artifacts' / f'whole-page-{name}.png').convert('RGBA')
        if actual.size != expected.size:
            raise ValueError('Output dimensions differ from independent source-row extent')
        a, b = np.asarray(actual), np.asarray(expected)
        different = int(np.count_nonzero(np.any(a != b, axis=2)))
        maximum = int(np.max(np.abs(a.astype(np.int16) - b.astype(np.int16))))
        expected.save(folder / f'independent-whole-page-{name}.png')
        results.append({'direction': name, 'success': different == 0, 'frames': len(images),
                        'pixelsCompared': actual.width * actual.height, 'differingPixels': different,
                        'maximumChannelError': maximum, 'sourcePositions': positions,
                        'completeDocument': True, 'productionMatcherUsed': False, 'CoreGraphicsCropUsed': False})
    except Exception as error:
        results.append({'direction': name, 'success': False, 'error': str(error)})
result = {'success': len(results) == 2 and all(r['success'] for r in results), 'cases': results}
(folder / 'verified-whole-page-png.json').write_text(json.dumps(result, indent=2))
print(json.dumps(result))
raise SystemExit(0 if result['success'] else 1)
