"""Exercise the actual larval model and save real activity for rendering checks."""
from pathlib import Path
import json
import sys

root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root / 'brain_service'))
from brain_service import LarvaBrain

brain = LarvaBrain(root / 'brain_service/data/larva')
request = {'fly_id': 'LARVA-TEST', 'life_stage': 'larva', 'inputs': {'sugar': 0.9, 'hunger': 0.6}}
total = 0
visible = 0
best = {}
for seq in range(60):
    request['seq'] = seq + 1
    activity = brain.step(request)['activity']
    assert set(activity['spike_ids']).issubset(set(brain.ids)), 'Unknown neuron ID'
    assert activity['fired_count'] == len(activity['spike_ids'])
    total += activity['fired_count']
    rates = activity['neuron_rates_hz']
    if max(rates.values(), default=0) > 0:
        visible += 1
        best = activity
assert total > 0 and visible > 0, 'Larval response must reach displayed morphology'
(root / 'build').mkdir(exist_ok=True)
(root / 'build/larva_verified_activity.json').write_text(json.dumps(best), encoding='utf-8')
print(json.dumps({'model_neurons': len(brain.ids), 'steps': 60, 'spikes': total, 'visible_activity_windows': visible, 'example_rates_hz': best['neuron_rates_hz']}))
