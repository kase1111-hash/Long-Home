#!/usr/bin/env python3
"""
End-to-End Procedural Generation Test Suite for Long-Home

Tests the terrain generation pipeline without Godot runtime:
- Heightmap generation and resampling
- Slope analysis (Sobel-based gradient calculation)
- Surface classification logic
- Terrain zone classification
- Cliff detection and exit zone identification
- Full procedural generation pipeline
"""

import math
import random
from dataclasses import dataclass, field
from typing import Dict, List, Tuple, Optional, Set
from enum import IntEnum
import sys

# =============================================================================
# ENUMS (Mirror GDScript enums)
# =============================================================================

class SurfaceType(IntEnum):
    SNOW_FIRM = 0
    SNOW_SOFT = 1
    SNOW_POWDER = 2
    ICE = 3
    ROCK = 4
    ROCK_DRY = 5
    ROCK_WET = 6
    SCREE = 7
    MIXED = 8

class TerrainZone(IntEnum):
    WALKABLE = 0
    STEEP = 1
    SLIDEABLE = 2
    DOWNCLIMB = 3
    RAPPEL_REQUIRED = 4
    CLIFF = 5

# Slope thresholds (from enums.gd)
SLOPE_THRESHOLDS = {
    "walkable_max": 25.0,
    "slide_min": 25.0,
    "slide_max": 40.0,
    "downclimb_min": 35.0,
    "downclimb_max": 50.0,
    "rappel_min": 50.0,
    "cliff_min": 70.0
}

SURFACE_FRICTION = {
    SurfaceType.SNOW_FIRM: 0.3,
    SurfaceType.SNOW_SOFT: 0.5,
    SurfaceType.SNOW_POWDER: 0.6,
    SurfaceType.ICE: 0.1,
    SurfaceType.ROCK: 0.6,
    SurfaceType.ROCK_DRY: 0.7,
    SurfaceType.ROCK_WET: 0.2,
    SurfaceType.SCREE: 0.6,
    SurfaceType.MIXED: 0.4
}

# =============================================================================
# VECTOR CLASSES
# =============================================================================

@dataclass
class Vector2i:
    x: int = 0
    y: int = 0

@dataclass
class Vector3:
    x: float = 0.0
    y: float = 0.0
    z: float = 0.0

    def length(self) -> float:
        return math.sqrt(self.x**2 + self.y**2 + self.z**2)

    def normalized(self) -> 'Vector3':
        l = self.length()
        if l < 0.0001:
            return Vector3(0, 0, 0)
        return Vector3(self.x/l, self.y/l, self.z/l)

    def distance_to(self, other: 'Vector3') -> float:
        return math.sqrt((self.x - other.x)**2 + (self.y - other.y)**2 + (self.z - other.z)**2)

# =============================================================================
# TERRAIN CELL
# =============================================================================

@dataclass
class TerrainCell:
    """Mirror of TerrainCell.gd"""
    position: Vector3 = field(default_factory=Vector3)
    grid_coords: Vector2i = field(default_factory=Vector2i)
    elevation: float = 0.0
    slope_angle: float = 0.0
    slope_direction: Vector3 = field(default_factory=Vector3)
    aspect: float = 0.0
    normal: Vector3 = field(default_factory=lambda: Vector3(0, 1, 0))
    curvature: float = 0.0
    terrain_zone: TerrainZone = TerrainZone.WALKABLE
    surface_type: SurfaceType = SurfaceType.SNOW_FIRM
    friction: float = 0.5
    distance_to_cliff: float = 1000.0
    cliff_direction: Vector3 = field(default_factory=Vector3)
    is_cliff: bool = False
    is_exit_zone: bool = False
    exit_zone_quality: float = 0.0
    drainage: float = 0.0
    is_walkable: bool = True
    requires_rope: bool = False
    is_slideable: bool = False
    slide_risk: float = 0.0
    sun_exposure: float = 0.5
    ice_probability: float = 0.0

    def calculate_derived_properties(self):
        """Calculate properties derived from basic values"""
        # Terrain zone from slope
        self.terrain_zone = get_terrain_zone(self.slope_angle)

        # Friction from surface
        self.friction = SURFACE_FRICTION.get(self.surface_type, 0.5)

        # Navigation flags
        self.is_cliff = self.slope_angle >= SLOPE_THRESHOLDS["cliff_min"]
        self.is_walkable = self.terrain_zone in [TerrainZone.WALKABLE, TerrainZone.STEEP]
        self.requires_rope = self.terrain_zone in [TerrainZone.RAPPEL_REQUIRED, TerrainZone.CLIFF]
        self.is_slideable = (
            self.slope_angle >= SLOPE_THRESHOLDS["slide_min"] and
            self.slope_angle <= SLOPE_THRESHOLDS["slide_max"] and
            self.surface_type in [
                SurfaceType.SNOW_FIRM,
                SurfaceType.SNOW_SOFT,
                SurfaceType.SNOW_POWDER,
                SurfaceType.SCREE
            ]
        )

        # Exit zone detection
        self.is_exit_zone = (
            self.slope_angle < SLOPE_THRESHOLDS["slide_min"] and
            self.curvature < 0.2 and
            not self.is_cliff and
            self.distance_to_cliff > 10.0
        )

        if self.is_exit_zone:
            self.exit_zone_quality = 1.0 - (self.slope_angle / SLOPE_THRESHOLDS["slide_min"])
            self.exit_zone_quality *= min(1.0, self.distance_to_cliff / 50.0)

        # Slide risk calculation
        if self.is_slideable:
            self.slide_risk = 0.0
            self.slide_risk += (self.slope_angle - SLOPE_THRESHOLDS["slide_min"]) / 15.0 * 0.3
            if self.distance_to_cliff < 50.0:
                self.slide_risk += (1.0 - self.distance_to_cliff / 50.0) * 0.5
            self.slide_risk += self.ice_probability * 0.2
            self.slide_risk = max(0.0, min(1.0, self.slide_risk))

# =============================================================================
# TERRAIN CHUNK
# =============================================================================

class TerrainChunk:
    """Mirror of TerrainChunk.gd"""

    DEFAULT_CHUNK_SIZE = 64.0
    DEFAULT_RESOLUTION = 32

    def __init__(self, coords: Vector2i = None, size: float = None, resolution: int = None):
        self.chunk_coords = coords or Vector2i(0, 0)
        self.chunk_size = size or self.DEFAULT_CHUNK_SIZE
        self.resolution = resolution or self.DEFAULT_RESOLUTION
        self.cell_size = self.chunk_size / self.resolution

        self.world_origin = Vector3(
            self.chunk_coords.x * self.chunk_size,
            0.0,
            self.chunk_coords.y * self.chunk_size
        )

        self.cells: List[List[TerrainCell]] = []
        self.heightmap: List[float] = []
        self.min_elevation = 0.0
        self.max_elevation = 0.0
        self.average_slope = 0.0
        self.is_analyzed = False

        self.cliff_cells: List[Vector2i] = []
        self.exit_zone_cells: List[Vector2i] = []
        self.rope_required_cells: List[Vector2i] = []

        self._initialize_cells()

    def _initialize_cells(self):
        self.cells = []
        for x in range(self.resolution):
            column = []
            for z in range(self.resolution):
                world_pos = self._grid_to_world(Vector2i(x, z))
                cell = TerrainCell(position=world_pos, grid_coords=Vector2i(x, z))
                column.append(cell)
            self.cells.append(column)

        self.heightmap = [0.0] * (self.resolution * self.resolution)

    def _grid_to_world(self, grid_pos: Vector2i) -> Vector3:
        return Vector3(
            self.world_origin.x + grid_pos.x * self.cell_size + self.cell_size * 0.5,
            0.0,
            self.world_origin.z + grid_pos.y * self.cell_size + self.cell_size * 0.5
        )

    def get_cell(self, grid_pos: Vector2i) -> Optional[TerrainCell]:
        if not self._is_valid_grid_pos(grid_pos):
            return None
        return self.cells[grid_pos.x][grid_pos.y]

    def get_height(self, grid_pos: Vector2i) -> float:
        if not self._is_valid_grid_pos(grid_pos):
            return 0.0
        return self.heightmap[grid_pos.y * self.resolution + grid_pos.x]

    def set_height(self, grid_pos: Vector2i, height: float):
        if not self._is_valid_grid_pos(grid_pos):
            return
        self.heightmap[grid_pos.y * self.resolution + grid_pos.x] = height
        cell = self.get_cell(grid_pos)
        if cell:
            cell.elevation = height
            cell.position.y = height

    def _is_valid_grid_pos(self, grid_pos: Vector2i) -> bool:
        return (0 <= grid_pos.x < self.resolution and 0 <= grid_pos.y < self.resolution)

    def load_heightmap(self, data: List[float], data_resolution: int):
        """Load heightmap from float array"""
        if len(data) != data_resolution * data_resolution:
            raise ValueError("Heightmap data size mismatch")

        if data_resolution == self.resolution:
            self.heightmap = data[:]
        else:
            self._resample_heightmap(data, data_resolution)

        # Update cell elevations
        for x in range(self.resolution):
            for z in range(self.resolution):
                height = self.get_height(Vector2i(x, z))
                cell = self.get_cell(Vector2i(x, z))
                cell.elevation = height
                cell.position.y = height

        self._update_elevation_bounds()

    def _resample_heightmap(self, data: List[float], data_res: int):
        """Resample heightmap to chunk resolution using bilinear interpolation"""
        for z in range(self.resolution):
            for x in range(self.resolution):
                src_x = float(x) / self.resolution * data_res
                src_z = float(z) / self.resolution * data_res

                x0 = int(src_x)
                z0 = int(src_z)
                x1 = min(x0 + 1, data_res - 1)
                z1 = min(z0 + 1, data_res - 1)

                fx = src_x - x0
                fz = src_z - z0

                h00 = data[z0 * data_res + x0]
                h10 = data[z0 * data_res + x1]
                h01 = data[z1 * data_res + x0]
                h11 = data[z1 * data_res + x1]

                h0 = h00 + (h10 - h00) * fx
                h1 = h01 + (h11 - h01) * fx
                height = h0 + (h1 - h0) * fz

                self.heightmap[z * self.resolution + x] = height

    def _update_elevation_bounds(self):
        if not self.heightmap:
            return
        self.min_elevation = min(self.heightmap)
        self.max_elevation = max(self.heightmap)

    def analyze(self):
        """Analyze all cells in this chunk"""
        slope_sum = 0.0

        self.cliff_cells.clear()
        self.exit_zone_cells.clear()
        self.rope_required_cells.clear()

        for x in range(self.resolution):
            for z in range(self.resolution):
                cell = self.get_cell(Vector2i(x, z))
                self._analyze_cell(cell, x, z)
                slope_sum += cell.slope_angle

        self.average_slope = slope_sum / (self.resolution * self.resolution)

        # Calculate cliff distances
        self._calculate_cliff_distances()

        # Final pass: derive all dependent properties
        for x in range(self.resolution):
            for z in range(self.resolution):
                cell = self.get_cell(Vector2i(x, z))
                cell.calculate_derived_properties()

                # Collect special cells
                if cell.is_cliff:
                    self.cliff_cells.append(Vector2i(x, z))
                if cell.is_exit_zone:
                    self.exit_zone_cells.append(Vector2i(x, z))
                if cell.requires_rope:
                    self.rope_required_cells.append(Vector2i(x, z))

        self.is_analyzed = True

    def _analyze_cell(self, cell: TerrainCell, x: int, z: int):
        """Calculate slope from neighbors using Sobel-like filter"""
        neighbors = self._get_neighbor_heights(x, z)

        # Gradient using Sobel-like filter
        dx = (neighbors['e'] - neighbors['w']) / (2.0 * self.cell_size)
        dz = (neighbors['s'] - neighbors['n']) / (2.0 * self.cell_size)

        # Slope angle
        gradient = math.sqrt(dx * dx + dz * dz)
        cell.slope_angle = math.degrees(math.atan(gradient))

        # Normal vector
        normal = Vector3(-dx, 1.0, -dz).normalized()
        cell.normal = normal

        # Slope direction (downhill)
        if gradient > 0.001:
            cell.slope_direction = Vector3(dx, 0.0, dz).normalized()
        else:
            cell.slope_direction = Vector3(0, 0, 0)

        # Aspect (compass direction of slope face)
        if gradient > 0.001:
            cell.aspect = math.degrees(math.atan2(dx, -dz))
            if cell.aspect < 0:
                cell.aspect += 360.0

        # Curvature (second derivative)
        center = cell.elevation
        d2x = (neighbors['e'] + neighbors['w'] - 2.0 * center) / (self.cell_size * self.cell_size)
        d2z = (neighbors['n'] + neighbors['s'] - 2.0 * center) / (self.cell_size * self.cell_size)
        cell.curvature = (d2x + d2z) * 0.5

        # Drainage
        cell.drainage = max(0.0, min(1.0, -cell.curvature * 10.0))

    def _get_neighbor_heights(self, x: int, z: int) -> Dict[str, float]:
        return {
            'n': self.get_height(Vector2i(x, max(z - 1, 0))),
            's': self.get_height(Vector2i(x, min(z + 1, self.resolution - 1))),
            'e': self.get_height(Vector2i(min(x + 1, self.resolution - 1), z)),
            'w': self.get_height(Vector2i(max(x - 1, 0), z)),
            'c': self.get_height(Vector2i(x, z))
        }

    def _calculate_cliff_distances(self):
        """Calculate distance to nearest cliff for each cell"""
        # First, identify cliff cells
        cliff_positions = []
        for x in range(self.resolution):
            for z in range(self.resolution):
                cell = self.get_cell(Vector2i(x, z))
                if cell.slope_angle >= SLOPE_THRESHOLDS["cliff_min"]:
                    cliff_positions.append((x, z, cell.position))

        # For each cell, find distance to nearest cliff
        for x in range(self.resolution):
            for z in range(self.resolution):
                cell = self.get_cell(Vector2i(x, z))
                min_dist = 1000.0
                cliff_dir = Vector3(0, 0, 0)

                for cx, cz, cliff_pos in cliff_positions:
                    dist = cell.position.distance_to(cliff_pos)
                    if dist < min_dist:
                        min_dist = dist
                        if dist > 0.001:
                            cliff_dir = Vector3(
                                cliff_pos.x - cell.position.x,
                                cliff_pos.y - cell.position.y,
                                cliff_pos.z - cell.position.z
                            ).normalized()

                cell.distance_to_cliff = min_dist
                cell.cliff_direction = cliff_dir

# =============================================================================
# HELPER FUNCTIONS
# =============================================================================

def get_terrain_zone(slope_angle: float) -> TerrainZone:
    """Get terrain zone from slope angle"""
    if slope_angle >= SLOPE_THRESHOLDS["cliff_min"]:
        return TerrainZone.CLIFF
    elif slope_angle >= SLOPE_THRESHOLDS["rappel_min"]:
        return TerrainZone.RAPPEL_REQUIRED
    elif slope_angle >= SLOPE_THRESHOLDS["downclimb_min"]:
        return TerrainZone.DOWNCLIMB
    elif slope_angle >= SLOPE_THRESHOLDS["slide_min"]:
        return TerrainZone.SLIDEABLE
    elif slope_angle >= SLOPE_THRESHOLDS["walkable_max"]:
        return TerrainZone.STEEP
    else:
        return TerrainZone.WALKABLE

# =============================================================================
# HEIGHTMAP GENERATORS
# =============================================================================

def generate_flat_heightmap(resolution: int, base_height: float = 3000.0) -> List[float]:
    """Generate a flat heightmap"""
    return [base_height] * (resolution * resolution)

def generate_slope_heightmap(resolution: int, base_height: float = 3000.0,
                             slope_degrees: float = 30.0) -> List[float]:
    """Generate a uniform slope heightmap"""
    heightmap = []
    slope_rad = math.radians(slope_degrees)
    drop_per_cell = math.tan(slope_rad) * (64.0 / resolution)

    for z in range(resolution):
        for x in range(resolution):
            height = base_height - z * drop_per_cell
            heightmap.append(height)

    return heightmap

def generate_mountain_heightmap(resolution: int, base_height: float = 2500.0,
                                peak_height: float = 4000.0, seed: int = 42,
                                chunk_size: float = 64.0) -> List[float]:
    """Generate a procedural mountain heightmap with realistic slope gradients

    Args:
        resolution: Grid resolution
        base_height: Base elevation
        peak_height: Peak elevation (used for scaling)
        seed: Random seed
        chunk_size: Size of chunk in world units (affects slope steepness)
    """
    random.seed(seed)

    size = resolution
    heightmap = [0.0] * (size * size)
    center = size // 2

    def idx(x, z):
        return z * size + x

    cell_size = chunk_size / resolution
    max_dist_cells = math.sqrt(center**2 + center**2)
    max_world_dist = max_dist_cells * cell_size

    # Calculate height difference to achieve target average slopes
    # For a mountain section, we want mix of zones:
    # - Some flat areas (~10-15°)
    # - Some slideable areas (25-40°)
    # - Some steep areas (40-60°)
    # Average around 25-30°
    # tan(30°) ≈ 0.577, so height_diff = 0.577 * horizontal_distance
    target_avg_slope = 0.6  # tan(~30°)
    max_height_diff = target_avg_slope * max_world_dist

    for z in range(size):
        for x in range(size):
            # Distance from center normalized (0 to 1)
            dist_cells = math.sqrt((x - center)**2 + (z - center)**2)
            dist_normalized = dist_cells / max_dist_cells

            # Create varied terrain with different zones
            # Use a sigmoid-like profile with noise

            # Base falloff
            falloff = 1.0 - dist_normalized

            # Add variation to create different slope regions
            angle = math.atan2(z - center, x - center)
            ridge_factor = 0.3 * math.sin(angle * 3 + seed * 0.1)

            # Create some steeper and flatter regions
            variation = math.sin(x * 0.3 + seed) * math.cos(z * 0.25) * 0.2

            falloff = max(0, falloff + variation + ridge_factor * (1 - dist_normalized))

            # Add controlled noise
            noise = random.uniform(-0.08, 0.08)

            # Calculate height with the profile
            height = base_height + max_height_diff * max(0, falloff + noise)

            heightmap[idx(x, z)] = height

    # Ensure peak is at center
    heightmap[idx(center, center)] = base_height + max_height_diff

    return heightmap

def generate_cliff_heightmap(resolution: int, base_height: float = 3000.0,
                             cliff_position: float = 0.5) -> List[float]:
    """Generate heightmap with a cliff band"""
    heightmap = []
    cliff_z = int(resolution * cliff_position)
    cliff_height = 200.0  # Vertical drop

    for z in range(resolution):
        for x in range(resolution):
            if z < cliff_z:
                height = base_height
            elif z == cliff_z:
                # Cliff face - very steep
                height = base_height - cliff_height * 0.5
            else:
                height = base_height - cliff_height

            # Add some variation
            height += math.sin(x * 0.3) * 5.0
            heightmap.append(height)

    return heightmap

# =============================================================================
# TEST SUITE
# =============================================================================

class TestResult:
    def __init__(self, name: str):
        self.name = name
        self.passed = True
        self.errors: List[str] = []

    def fail(self, message: str):
        self.passed = False
        self.errors.append(message)

def run_tests() -> bool:
    """Run all procedural generation tests"""
    print("=" * 60)
    print("PROCEDURAL GENERATION END-TO-END TEST")
    print("=" * 60)
    print()

    results: List[TestResult] = []

    # Test 1: Flat terrain
    results.append(test_flat_terrain())

    # Test 2: Uniform slope
    results.append(test_uniform_slope())

    # Test 3: Cliff detection
    results.append(test_cliff_detection())

    # Test 4: Mountain generation
    results.append(test_mountain_generation())

    # Test 5: Terrain zone classification
    results.append(test_terrain_zones())

    # Test 6: Exit zone detection
    results.append(test_exit_zones())

    # Test 7: Heightmap resampling
    results.append(test_heightmap_resampling())

    # Test 8: Surface classification simulation
    results.append(test_surface_classification())

    # Test 9: Full pipeline integration
    results.append(test_full_pipeline())

    # Print results
    print()
    print("=" * 60)
    print("TEST RESULTS")
    print("=" * 60)
    print()

    passed = 0
    failed = 0

    for result in results:
        status = "PASS" if result.passed else "FAIL"
        icon = "✓" if result.passed else "✗"
        print(f"  {icon} {result.name}: {status}")

        if not result.passed:
            for error in result.errors:
                print(f"      - {error}")
            failed += 1
        else:
            passed += 1

    print()
    print("=" * 60)
    print(f"SUMMARY: {passed} passed, {failed} failed")
    print("=" * 60)

    return failed == 0

def test_flat_terrain() -> TestResult:
    """Test flat terrain generation"""
    result = TestResult("Flat Terrain Analysis")

    chunk = TerrainChunk(Vector2i(0, 0), 64.0, 16)
    heightmap = generate_flat_heightmap(16, 3000.0)
    chunk.load_heightmap(heightmap, 16)
    chunk.analyze()

    # All cells should be nearly flat
    for x in range(chunk.resolution):
        for z in range(chunk.resolution):
            cell = chunk.get_cell(Vector2i(x, z))
            if cell.slope_angle > 1.0:
                result.fail(f"Flat terrain has slope {cell.slope_angle:.1f}° at ({x}, {z})")
                return result

    # Should all be walkable
    if chunk.average_slope > 1.0:
        result.fail(f"Average slope {chunk.average_slope:.1f}° too high for flat terrain")

    # Should have exit zones
    if len(chunk.exit_zone_cells) < 10:
        result.fail(f"Expected many exit zones, found {len(chunk.exit_zone_cells)}")

    return result

def test_uniform_slope() -> TestResult:
    """Test uniform slope generation and analysis"""
    result = TestResult("Uniform Slope Analysis")

    chunk = TerrainChunk(Vector2i(0, 0), 64.0, 16)
    target_slope = 30.0
    heightmap = generate_slope_heightmap(16, 3000.0, target_slope)
    chunk.load_heightmap(heightmap, 16)
    chunk.analyze()

    # Check average slope is close to target
    slope_tolerance = 5.0  # degrees
    if abs(chunk.average_slope - target_slope) > slope_tolerance:
        result.fail(f"Average slope {chunk.average_slope:.1f}° differs from target {target_slope}°")

    # Interior cells should have consistent slope
    for x in range(2, chunk.resolution - 2):
        for z in range(2, chunk.resolution - 2):
            cell = chunk.get_cell(Vector2i(x, z))
            if abs(cell.slope_angle - target_slope) > slope_tolerance:
                result.fail(f"Cell ({x},{z}) slope {cell.slope_angle:.1f}° differs from target")
                return result

    # Check terrain zone
    sample_cell = chunk.get_cell(Vector2i(8, 8))
    expected_zone = TerrainZone.SLIDEABLE  # 30° is in slide range
    if sample_cell.terrain_zone != expected_zone:
        result.fail(f"Expected zone {expected_zone.name}, got {sample_cell.terrain_zone.name}")

    return result

def test_cliff_detection() -> TestResult:
    """Test cliff detection in terrain"""
    result = TestResult("Cliff Detection")

    chunk = TerrainChunk(Vector2i(0, 0), 64.0, 16)
    heightmap = generate_cliff_heightmap(16, 3000.0, 0.5)
    chunk.load_heightmap(heightmap, 16)
    chunk.analyze()

    # Should have some cliff cells
    if len(chunk.cliff_cells) == 0:
        result.fail("No cliff cells detected in cliff terrain")
        return result

    # Cliff cells should be around the cliff band (z ≈ 8)
    cliff_z_values = [pos.y for pos in chunk.cliff_cells]
    avg_cliff_z = sum(cliff_z_values) / len(cliff_z_values) if cliff_z_values else 0

    if abs(avg_cliff_z - 8) > 2:
        result.fail(f"Cliff cells at unexpected z positions (avg: {avg_cliff_z:.1f}, expected ~8)")

    # Cells near cliff should have low distance_to_cliff
    cell_near_cliff = chunk.get_cell(Vector2i(8, 7))
    if cell_near_cliff.distance_to_cliff > 20.0:
        result.fail(f"Cell near cliff has large cliff distance: {cell_near_cliff.distance_to_cliff:.1f}m")

    # Cells far from cliff should have larger distance
    cell_far = chunk.get_cell(Vector2i(8, 0))
    if cell_far.distance_to_cliff < 20.0:
        result.fail(f"Cell far from cliff has small cliff distance: {cell_far.distance_to_cliff:.1f}m")

    return result

def test_mountain_generation() -> TestResult:
    """Test procedural mountain generation"""
    result = TestResult("Mountain Generation")

    # Use a larger chunk (256m) for more realistic mountain terrain
    chunk = TerrainChunk(Vector2i(0, 0), 256.0, 32)
    heightmap = generate_mountain_heightmap(32, 2500.0, 4000.0, seed=42, chunk_size=256.0)
    chunk.load_heightmap(heightmap, 32)
    chunk.analyze()

    # Check elevation range - for a 256m chunk, expect ~60-100m range
    # (This represents a section of mountain, not the whole peak)
    if chunk.max_elevation <= chunk.min_elevation:
        result.fail(f"Invalid elevation range: {chunk.min_elevation:.0f} - {chunk.max_elevation:.0f}")

    elevation_range = chunk.max_elevation - chunk.min_elevation
    if elevation_range < 20:
        result.fail(f"Mountain too flat, elevation range only {elevation_range:.0f}m")

    # Should have variety of terrain zones (at least walkable/steep/slideable)
    zones_found = set()
    for x in range(chunk.resolution):
        for z in range(chunk.resolution):
            cell = chunk.get_cell(Vector2i(x, z))
            zones_found.add(cell.terrain_zone)

    if len(zones_found) < 2:
        result.fail(f"Too few terrain zones: {[z.name for z in zones_found]}")

    # Peak should be near center (within tolerance)
    # Note: noise can create slightly higher points elsewhere
    center = chunk.resolution // 2
    peak_cell = chunk.get_cell(Vector2i(center, center))
    tolerance = chunk.max_elevation - chunk.min_elevation  # Allow up to full range as tolerance
    if peak_cell.elevation < chunk.max_elevation - tolerance * 0.3:
        result.fail(f"Peak not at center. Center elevation: {peak_cell.elevation:.0f}, max: {chunk.max_elevation:.0f}")

    return result

def test_terrain_zones() -> TestResult:
    """Test terrain zone classification"""
    result = TestResult("Terrain Zone Classification")

    # Test each zone threshold
    test_cases = [
        (10.0, TerrainZone.WALKABLE),
        (25.0, TerrainZone.SLIDEABLE),
        (30.0, TerrainZone.SLIDEABLE),
        (40.0, TerrainZone.DOWNCLIMB),
        (55.0, TerrainZone.RAPPEL_REQUIRED),
        (75.0, TerrainZone.CLIFF),
    ]

    for slope, expected_zone in test_cases:
        zone = get_terrain_zone(slope)
        if zone != expected_zone:
            result.fail(f"Slope {slope}° should be {expected_zone.name}, got {zone.name}")

    # Test cell derived properties
    cell = TerrainCell()
    cell.slope_angle = 32.0
    cell.surface_type = SurfaceType.SNOW_FIRM
    cell.distance_to_cliff = 100.0
    cell.curvature = 0.0
    cell.calculate_derived_properties()

    if not cell.is_slideable:
        result.fail(f"32° snow slope should be slideable")

    if cell.requires_rope:
        result.fail(f"32° slope should not require rope")

    return result

def test_exit_zones() -> TestResult:
    """Test exit zone detection"""
    result = TestResult("Exit Zone Detection")

    # Create terrain with clear exit zones (flat areas)
    chunk = TerrainChunk(Vector2i(0, 0), 64.0, 16)
    heightmap = []

    for z in range(16):
        for x in range(16):
            if z < 4 or z > 12:
                # Flat areas at top and bottom
                height = 3000.0
            else:
                # Slope in the middle
                height = 3000.0 - (z - 4) * 15.0
            heightmap.append(height)

    chunk.load_heightmap(heightmap, 16)
    chunk.analyze()

    # Should have exit zones in flat areas
    if len(chunk.exit_zone_cells) == 0:
        result.fail("No exit zones detected")
        return result

    # Exit zones should be in flat areas (z < 4 or z > 12)
    for exit_pos in chunk.exit_zone_cells:
        cell = chunk.get_cell(exit_pos)
        if cell.slope_angle > SLOPE_THRESHOLDS["slide_min"]:
            result.fail(f"Exit zone at ({exit_pos.x}, {exit_pos.y}) has slope {cell.slope_angle:.1f}°")
            return result

    return result

def test_heightmap_resampling() -> TestResult:
    """Test heightmap resampling accuracy"""
    result = TestResult("Heightmap Resampling")

    # Create high-res heightmap
    high_res = 64
    low_res = 16

    heightmap_high = []
    for z in range(high_res):
        for x in range(high_res):
            # Smooth gradient
            height = 3000.0 + math.sin(x * 0.1) * 50.0 + z * 5.0
            heightmap_high.append(height)

    # Create chunk with lower resolution
    chunk = TerrainChunk(Vector2i(0, 0), 64.0, low_res)
    chunk.load_heightmap(heightmap_high, high_res)

    # Check that resampling preserved general shape
    # Compare corner values
    corners = [
        (0, 0),
        (low_res - 1, 0),
        (0, low_res - 1),
        (low_res - 1, low_res - 1)
    ]

    for x, z in corners:
        resampled_height = chunk.get_height(Vector2i(x, z))

        # Calculate expected height from high-res
        src_x = x * high_res // low_res
        src_z = z * high_res // low_res
        original_height = heightmap_high[src_z * high_res + src_x]

        diff = abs(resampled_height - original_height)
        if diff > 50.0:  # Allow some interpolation error
            result.fail(f"Resampling error at ({x},{z}): expected ~{original_height:.0f}, got {resampled_height:.0f}")

    return result

def test_surface_classification() -> TestResult:
    """Test surface classification logic"""
    result = TestResult("Surface Classification")

    # Test friction values
    for surface_type, expected_friction in SURFACE_FRICTION.items():
        if surface_type == SurfaceType.ICE and expected_friction > 0.2:
            result.fail(f"Ice should have very low friction, got {expected_friction}")
        if surface_type == SurfaceType.ROCK_DRY and expected_friction < 0.5:
            result.fail(f"Dry rock should have high friction, got {expected_friction}")

    # Test ice surface properties
    cell_ice = TerrainCell()
    cell_ice.surface_type = SurfaceType.ICE
    cell_ice.slope_angle = 35.0
    cell_ice.distance_to_cliff = 30.0
    cell_ice.ice_probability = 0.8
    cell_ice.curvature = 0.0
    cell_ice.calculate_derived_properties()

    # Ice is NOT slideable (too dangerous - different mechanic in game)
    if cell_ice.is_slideable:
        result.fail("Ice surface should not be marked as slideable")

    # Ice should have very low friction
    if cell_ice.friction > 0.2:
        result.fail(f"Ice should have low friction, got {cell_ice.friction:.2f}")

    # Test snow surface properties (slideable)
    cell_snow = TerrainCell()
    cell_snow.surface_type = SurfaceType.SNOW_FIRM
    cell_snow.slope_angle = 32.0
    cell_snow.distance_to_cliff = 25.0
    cell_snow.ice_probability = 0.0
    cell_snow.curvature = 0.0
    cell_snow.calculate_derived_properties()

    # Snow on 32° slope should be slideable
    if not cell_snow.is_slideable:
        result.fail("Firm snow on 32° slope should be slideable")

    # Should have some slide risk due to cliff proximity
    if cell_snow.slide_risk < 0.2:
        result.fail(f"Snow near cliff should have slide risk, got {cell_snow.slide_risk:.2f}")

    return result

def test_full_pipeline() -> TestResult:
    """Test full procedural generation pipeline"""
    result = TestResult("Full Pipeline Integration")

    # Generate a realistic mountain chunk (256m for realistic scale)
    chunk = TerrainChunk(Vector2i(0, 0), 256.0, 32)
    heightmap = generate_mountain_heightmap(32, 2800.0, 3800.0, seed=123, chunk_size=256.0)

    # Load and analyze
    chunk.load_heightmap(heightmap, 32)
    chunk.analyze()

    # Verify analysis completed
    if not chunk.is_analyzed:
        result.fail("Chunk not marked as analyzed")
        return result

    # Statistics
    stats = {
        "total_cells": chunk.resolution * chunk.resolution,
        "cliff_cells": len(chunk.cliff_cells),
        "exit_zones": len(chunk.exit_zone_cells),
        "rope_required": len(chunk.rope_required_cells),
        "elevation_range": chunk.max_elevation - chunk.min_elevation,
        "average_slope": chunk.average_slope
    }

    print(f"\n  Pipeline Stats:")
    print(f"    - Total cells: {stats['total_cells']}")
    print(f"    - Elevation range: {stats['elevation_range']:.0f}m")
    print(f"    - Average slope: {stats['average_slope']:.1f}°")
    print(f"    - Cliff cells: {stats['cliff_cells']}")
    print(f"    - Exit zones: {stats['exit_zones']}")
    print(f"    - Rope required: {stats['rope_required']}")

    # Validate reasonable results for a 256m mountain section
    if stats['elevation_range'] < 20:
        result.fail(f"Mountain too flat: {stats['elevation_range']:.0f}m range")

    if stats['average_slope'] < 5:
        result.fail(f"Average slope too low: {stats['average_slope']:.1f}°")

    if stats['average_slope'] > 50:
        result.fail(f"Average slope unrealistically high: {stats['average_slope']:.1f}°")

    # Check cell consistency
    for x in range(chunk.resolution):
        for z in range(chunk.resolution):
            cell = chunk.get_cell(Vector2i(x, z))

            # Derived properties should be set
            if cell.terrain_zone is None:
                result.fail(f"Cell ({x},{z}) has no terrain zone")
                return result

            # Consistency checks
            if cell.is_cliff and cell.slope_angle < SLOPE_THRESHOLDS["cliff_min"]:
                result.fail(f"Cell marked cliff with slope {cell.slope_angle:.1f}°")
                return result

            if cell.requires_rope and not (cell.is_cliff or cell.slope_angle >= SLOPE_THRESHOLDS["rappel_min"]):
                result.fail(f"Cell requires rope but slope is only {cell.slope_angle:.1f}°")
                return result

    return result

# =============================================================================
# MAIN
# =============================================================================

if __name__ == "__main__":
    success = run_tests()
    sys.exit(0 if success else 1)
