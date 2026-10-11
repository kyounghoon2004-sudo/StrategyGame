extends RefCounted

## CIV3D sortie paths (VISUAL ONLY): the smooth out-and-back routes a figure
## follows when its unit attacks — out to a strike point along an S-curve,
## then a U-turn outward, back down a lane beside the outbound one, a second
## U-turn behind home and the last stride onto home facing the front. Shared by
## foot formations and cavalry; positions are in the formation's local space.

## Outbound leg: home -> strike point (`reach` along f, `lat` across l, sweep
## bulge `bow`). Ends heading along f.
static func out_path(home: Vector3, f: Vector3, l: Vector3, reach: float, lat: float, bow: float) -> PackedVector3Array:
	var pts := PackedVector3Array()
	for i in range(0, 17):
		var u: float = float(i) / 16.0
		var s: float = u * u * (3.0 - 2.0 * u)
		pts.append(home + f * reach * u + l * (lat * s + bow * sin(PI * u)))
	return pts

## Return leg from the strike point: run on `over`, U-turn (radius r) to the
## `side`, back past home by `behind`, U-turn and stop on home facing `front`.
static func back_path(strike: Vector3, f: Vector3, l: Vector3, home: Vector3, front: Vector3, front_l: Vector3, r: float, side: float, behind: float, over: float) -> PackedVector3Array:
	var pts := PackedVector3Array()
	var turn0: Vector3 = strike + f * over
	pts.append(strike)
	if over > 0.01:
		pts.append(turn0)
	var c1: Vector3 = turn0 + l * side * r
	for i in range(1, 13):
		var th: float = PI * float(i) / 12.0
		pts.append(c1 - l * side * r * cos(th) + f * r * sin(th))
	var c2: Vector3 = home + front_l * side * r - front * behind
	var lane_start: Vector3 = pts[pts.size() - 1]
	var lane_end: Vector3 = c2 + front_l * side * r
	for i in range(1, 12):
		pts.append(lane_start.lerp(lane_end, float(i) / 11.0))
	for i in range(1, 13):
		var th: float = PI * float(i) / 12.0
		pts.append(c2 + front_l * side * r * cos(th) - front * r * sin(th))
	for i in range(1, 5):
		pts.append((home - front * behind).lerp(home, float(i) / 4.0))
	return pts

static func cumulative(path: PackedVector3Array) -> PackedFloat32Array:
	var cum := PackedFloat32Array([0.0])
	for i in range(1, path.size()):
		cum.append(cum[i - 1] + path[i].distance_to(path[i - 1]))
	return cum

## Seconds to cover `length` on a trapezoid speed profile.
static func duration(length: float, v: float, acc: float, dec: float) -> float:
	return length / v + 0.5 * (acc + dec)

## Distance covered after `t` s (accelerate over `acc` s, cruise at v, pull up over `dec` s).
static func dist_at(t: float, length: float, v: float, acc: float, dec: float) -> float:
	var d_acc: float = 0.5 * v * acc
	var d_dec: float = 0.5 * v * dec
	var t_cruise: float = maxf(0.0, (length - d_acc - d_dec) / v)
	if t <= acc:
		return 0.5 * v * t * t / acc
	t -= acc
	if t <= t_cruise:
		return d_acc + v * t
	t = minf(t - t_cruise, dec)
	return minf(length, d_acc + v * t_cruise + v * t - 0.5 * v * t * t / dec)

## Current speed (units / s) on the same profile.
static func speed_at(t: float, length: float, v: float, acc: float, dec: float) -> float:
	var t_cruise: float = maxf(0.0, (length - 0.5 * v * acc - 0.5 * v * dec) / v)
	if t <= acc:
		return v * t / acc
	if t <= acc + t_cruise:
		return v
	return v * maxf(0.0, 1.0 - (t - acc - t_cruise) / dec)

## [position, unit tangent] at distance d along the path.
static func at(path: PackedVector3Array, cum: PackedFloat32Array, d: float) -> Array:
	var n: int = path.size()
	if d <= 0.0:
		return [path[0], (path[1] - path[0]).normalized()]
	var i: int = cum.bsearch(d)
	if i >= n:
		return [path[n - 1], (path[n - 1] - path[n - 2]).normalized()]
	var seg: float = maxf(cum[i] - cum[i - 1], 0.0001)
	return [path[i - 1].lerp(path[i], (d - cum[i - 1]) / seg), (path[i] - path[i - 1]).normalized()]
