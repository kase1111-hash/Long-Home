class_name CliffDistanceField
extends RefCounted
## Two-pass chamfer distance transform over a grid of cliff flags.
## O(cells) instead of O(cells x cliff cells). Instead of propagating a
## distance alone, it propagates the index of the nearest cliff cell, so the
## caller can derive both the Euclidean distance and the direction to the
## nearest cliff from the result.

## Marker for "no cliff anywhere on the grid"
const NO_CLIFF := -1

## Chamfer weight for diagonal steps (in cell units)
const DIAGONAL_COST := 1.41421356


## Compute the nearest cliff cell index for every cell of a width x depth grid.
## cliff_mask[z * width + x] != 0 marks a cliff cell. The returned array holds,
## for each cell, the flat index (z * width + x) of its nearest cliff cell, or
## NO_CLIFF for every cell when the grid contains no cliffs at all.
static func compute_nearest(width: int, depth: int, cliff_mask: PackedByteArray) -> PackedInt32Array:
	var count := width * depth
	var nearest := PackedInt32Array()
	nearest.resize(count)
	nearest.fill(NO_CLIFF)

	var dist := PackedFloat32Array()
	dist.resize(count)
	dist.fill(1.0e9)

	var has_cliff := false
	for i in range(count):
		if cliff_mask[i] != 0:
			dist[i] = 0.0
			nearest[i] = i
			has_cliff = true

	if not has_cliff:
		return nearest

	# Forward pass: top-left to bottom-right, pulling from W, NW, N, NE
	for z in range(depth):
		var row := z * width
		for x in range(width):
			var i := row + x
			var best := dist[i]
			if best == 0.0:
				continue
			var best_src := nearest[i]
			var d: float
			if x > 0:
				d = dist[i - 1] + 1.0
				if d < best:
					best = d
					best_src = nearest[i - 1]
			if z > 0:
				var up := i - width
				d = dist[up] + 1.0
				if d < best:
					best = d
					best_src = nearest[up]
				if x > 0:
					d = dist[up - 1] + DIAGONAL_COST
					if d < best:
						best = d
						best_src = nearest[up - 1]
				if x < width - 1:
					d = dist[up + 1] + DIAGONAL_COST
					if d < best:
						best = d
						best_src = nearest[up + 1]
			dist[i] = best
			nearest[i] = best_src

	# Backward pass: bottom-right to top-left, pulling from E, SE, S, SW
	for z in range(depth - 1, -1, -1):
		var row := z * width
		for x in range(width - 1, -1, -1):
			var i := row + x
			var best := dist[i]
			if best == 0.0:
				continue
			var best_src := nearest[i]
			var d: float
			if x < width - 1:
				d = dist[i + 1] + 1.0
				if d < best:
					best = d
					best_src = nearest[i + 1]
			if z < depth - 1:
				var down := i + width
				d = dist[down] + 1.0
				if d < best:
					best = d
					best_src = nearest[down]
				if x < width - 1:
					d = dist[down + 1] + DIAGONAL_COST
					if d < best:
						best = d
						best_src = nearest[down + 1]
				if x > 0:
					d = dist[down - 1] + DIAGONAL_COST
					if d < best:
						best = d
						best_src = nearest[down - 1]
			dist[i] = best
			nearest[i] = best_src

	return nearest
