import runpy, struct, collections
d=runpy.run_path(str(__import__('pathlib').Path(__file__).with_name('inspect_source.py')))
doc,raw,base=d['doc'],d['raw'],d['bin_offset']
def values(i):
 a=doc['accessors'][i];v=doc['bufferViews'][a['bufferView']];fmt={5126:'f',5123:'H',5121:'B'}[a['componentType']];width=4*struct.calcsize(fmt)
 return [struct.unpack_from('<'+fmt*4,raw,base+v.get('byteOffset',0)+a.get('byteOffset',0)+j*v.get('byteStride',width)) for j in range(a['count'])]
for p in doc['meshes'][0]['primitives']:
 counts=collections.Counter()
 for joints,weights in zip(values(p['attributes']['JOINTS_0']),values(p['attributes']['WEIGHTS_0'])):
  for j,w in zip(joints,weights):
   if w>.01:counts[j]+=1
 print('WEIGHTED_VERTEX_INFLUENCES',dict(sorted(counts.items())))
