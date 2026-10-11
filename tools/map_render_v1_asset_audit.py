#!/usr/bin/env python3
"""Read-only topology audit for selected map-composition tree GLBs.

Uses only Python's standard library; reads raw GLB JSON/BIN chunks and prints
mesh/primitive counts, duplicate-face metrics, and vertex-connected components.
No Godot import, scene mutation, or rendering is performed.
"""
from __future__ import annotations

import json
import struct
from collections import Counter, defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TREE_DIR = ROOT / "assets/map_composition_v0/source_glb/trees"
TARGETS = {
    "large_conifer": "03-broad-layered-conifer.glb",
    "compact_pine": "04-compact-hill-pine.glb",
}
COMPONENT_FORMATS = {5121: "B", 5123: "H", 5125: "I", 5126: "f"}
COMPONENT_BYTES = {5121: 1, 5123: 2, 5125: 4, 5126: 4}
TYPE_WIDTHS = {"SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4, "MAT2": 4, "MAT3": 9, "MAT4": 16}


def read_glb(path: Path) -> tuple[dict, bytes]:
    data = path.read_bytes()
    magic, version, declared_len = struct.unpack_from("<4sII", data, 0)
    if magic != b"glTF" or version != 2 or declared_len != len(data):
        raise ValueError(f"invalid GLB v2 header: {path}")
    offset = 12
    document = None
    binary = b""
    while offset < len(data):
        chunk_len, chunk_type = struct.unpack_from("<II", data, offset)
        offset += 8
        chunk = data[offset : offset + chunk_len]
        offset += chunk_len
        if chunk_type == 0x4E4F534A:
            document = json.loads(chunk.decode("utf-8").rstrip("\0 \t\r\n"))
        elif chunk_type == 0x004E4942:
            binary = chunk
    if document is None:
        raise ValueError(f"GLB has no JSON chunk: {path}")
    return document, binary


def read_accessor(doc: dict, binary: bytes, index: int) -> list:
    accessor = doc["accessors"][index]
    view = doc["bufferViews"][accessor["bufferView"]]
    comp = accessor["componentType"]
    width = TYPE_WIDTHS[accessor["type"]]
    fmt = "<" + COMPONENT_FORMATS[comp] * width
    elem_bytes = COMPONENT_BYTES[comp] * width
    stride = view.get("byteStride", elem_bytes)
    start = view.get("byteOffset", 0) + accessor.get("byteOffset", 0)
    values = []
    for i in range(accessor["count"]):
        values.append(struct.unpack_from(fmt, binary, start + i * stride))
    if accessor["type"] == "SCALAR":
        return [v[0] for v in values]
    return values


class DisjointSet:
    def __init__(self, values):
        self.parent = {v: v for v in values}
        self.size = {v: 1 for v in values}

    def find(self, value):
        p = self.parent[value]
        if p != value:
            self.parent[value] = self.find(p)
        return self.parent[value]

    def union(self, a, b):
        ra, rb = self.find(a), self.find(b)
        if ra == rb:
            return
        if self.size[ra] < self.size[rb]:
            ra, rb = rb, ra
        self.parent[rb] = ra
        self.size[ra] += self.size[rb]


def component_sizes(triangles: list[tuple[int, int, int]]) -> list[int]:
    used = {v for tri in triangles for v in tri}
    if not used:
        return []
    dsu = DisjointSet(used)
    for a, b, c in triangles:
        dsu.union(a, b)
        dsu.union(b, c)
    counts = Counter(dsu.find(v) for v in used)
    return sorted(counts.values(), reverse=True)


def audit_primitive(doc: dict, binary: bytes, primitive: dict) -> dict:
    attrs = primitive.get("attributes", {})
    positions = read_accessor(doc, binary, attrs["POSITION"])
    attribute_values = {name: read_accessor(doc, binary, index) for name, index in attrs.items()}
    if primitive.get("indices") is None:
        indices = list(range(len(positions)))
    else:
        indices = read_accessor(doc, binary, primitive["indices"])
    mode = primitive.get("mode", 4)
    if mode != 4:
        return {"mode": mode, "vertex_count": len(positions), "index_count": len(indices), "triangles": None}
    usable_count = len(indices) - len(indices) % 3
    triangles = [tuple(indices[i : i + 3]) for i in range(0, usable_count, 3)]
    coord_key = lambda v: tuple(float(x) for x in positions[v])
    position_normal_key = lambda v: (
        tuple(float(x) for x in attribute_values["POSITION"][v]),
        tuple(float(x) for x in attribute_values["NORMAL"][v]) if "NORMAL" in attribute_values else (),
    )
    full_vertex_key = lambda v: tuple(
        (name, tuple(float(x) for x in values[v]))
        for name, values in sorted(attribute_values.items())
    )
    index_faces = [tuple(sorted(t)) for t in triangles]
    coord_faces = [tuple(sorted(coord_key(v) for v in t)) for t in triangles]
    degenerate_indices = sum(len(set(t)) < 3 for t in triangles)
    degenerate_positions = sum(len({coord_key(v) for v in t}) < 3 for t in triangles)
    index_repeats = len(index_faces) - len(set(index_faces))
    coord_repeats = len(coord_faces) - len(set(coord_faces))
    vertex_positions = [tuple(float(x) for x in p) for p in positions]
    largest_components = component_sizes(triangles)
    position_ids = {p: i for i, p in enumerate(set(vertex_positions))}
    full_keys = [full_vertex_key(i) for i in range(len(positions))]
    pos_normal_keys = [position_normal_key(i) for i in range(len(positions))]
    full_ids = {p: i for i, p in enumerate(set(full_keys))}
    position_triangles = [tuple(position_ids[coord_key(v)] for v in tri) for tri in triangles]
    full_triangles = [tuple(full_ids[full_vertex_key(v)] for v in tri) for tri in triangles]
    position_components = component_sizes(position_triangles)
    full_components = component_sizes(full_triangles)
    attrs_per_position = defaultdict(set)
    normals_per_position = defaultdict(set)
    colors_per_position = defaultdict(set)
    for i, pos in enumerate(vertex_positions):
        attrs_per_position[pos].add(full_keys[i])
        if "NORMAL" in attribute_values:
            normals_per_position[pos].add(tuple(float(x) for x in attribute_values["NORMAL"][i]))
        if "COLOR_0" in attribute_values:
            colors_per_position[pos].add(tuple(float(x) for x in attribute_values["COLOR_0"][i]))
    seam_positions = sum(len(values) > 1 for values in attrs_per_position.values())
    normal_seam_positions = sum(len(values) > 1 for values in normals_per_position.values())
    color_seam_positions = sum(len(values) > 1 for values in colors_per_position.values())
    return {
        "mode": mode,
        "source_has_index_accessor": primitive.get("indices") is not None,
        "source_is_unindexed_triangle_list": primitive.get("indices") is None and mode == 4,
        "vertex_count": len(positions),
        "unique_position_count": len(set(vertex_positions)),
        "unique_full_vertex_count": len(set(full_keys)),
        "unique_position_normal_count": len(set(pos_normal_keys)),
        "positions_with_distinct_attribute_seams": seam_positions,
        "positions_with_normal_seams": normal_seam_positions,
        "positions_with_color_seams": color_seam_positions,
        "index_count": len(indices),
        "triangles": len(triangles),
        "index_duplicate_faces": index_repeats,
        "position_duplicate_faces": coord_repeats,
        "degenerate_index_faces": degenerate_indices,
        "degenerate_position_faces": degenerate_positions,
        "vertex_connected_components": len(largest_components),
        "position_connected_components": len(position_components),
        "full_attribute_connected_components": len(full_components),
        "largest_component_vertex_counts": largest_components[:8],
        "has_color_0": "COLOR_0" in attrs,
        "has_normal": "NORMAL" in attrs,
        "has_tangent": "TANGENT" in attrs,
        "has_texcoord_0": "TEXCOORD_0" in attrs,
    }


def audit_one(label: str, filename: str) -> dict:
    path = TREE_DIR / filename
    doc, binary = read_glb(path)
    mesh_nodes = []
    for node in doc.get("nodes", []):
        if "mesh" in node:
            mesh = doc["meshes"][node["mesh"]]
            mesh_nodes.append({
                "node": node.get("name", ""),
                "mesh": mesh.get("name", ""),
                "material_refs": [p.get("material") for p in mesh.get("primitives", [])],
                "primitives": [audit_primitive(doc, binary, p) for p in mesh.get("primitives", [])],
            })
    return {
        "label": label,
        "file": str(path),
        "materials": len(doc.get("materials", [])),
        "mesh_definitions": len(doc.get("meshes", [])),
        "mesh_nodes": mesh_nodes,
        "gltf_extensions_used": doc.get("extensionsUsed", []),
        "msft_lod_nodes": sum("MSFT_lod" in n.get("extensions", {}) for n in doc.get("nodes", [])),
    }


def main() -> None:
    print(json.dumps([audit_one(label, filename) for label, filename in TARGETS.items()], indent=2))


if __name__ == "__main__":
    main()
